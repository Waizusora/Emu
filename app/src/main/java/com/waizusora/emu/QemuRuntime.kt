package com.waizusora.emu

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Installs and probes the ABI-specific QEMU executables bundled by the CI build.
 * The binaries are copied to app-private storage before execution.
 */
object QemuRuntime {
    const val TARGET_VERSION = "9.2.0"

    data class RuntimeState(val available: Boolean, val status: String, val abi: String? = null)

    @Volatile
    private var currentState = RuntimeState(false, "QEMU runtime has not been initialized")

    fun isAvailable(): Boolean = currentState.available
    fun status(): String = currentState.status

    suspend fun initialize(context: Context): RuntimeState = withContext(Dispatchers.IO) {
        try {
            val abi = Build.SUPPORTED_ABIS.firstOrNull {
                it == "arm64-v8a" || it == "x86_64"
            } ?: error("This device ABI is not supported by the bundled QEMU runtime")

            val runtimeDirectory = File(context.noBackupFilesDir, "qemu/$abi")
            check(runtimeDirectory.exists() || runtimeDirectory.mkdirs()) {
                "Unable to create the private QEMU runtime directory"
            }

            val systemBinary = installAsset(context, abi, "qemu-system-aarch64", runtimeDirectory)
            val imageBinary = installAsset(context, abi, "qemu-img", runtimeDirectory)
            verifyElfMachine(systemBinary, abi)
            verifyElfMachine(imageBinary, abi)

            val systemVersion = runProbe(systemBinary, "--version")
            check(systemVersion.contains(TARGET_VERSION)) {
                "Unexpected qemu-system-aarch64 version: ${systemVersion.lineSequence().firstOrNull().orEmpty()}"
            }
            runProbe(systemBinary, "--help")

            val imageVersion = runProbe(imageBinary, "--version")
            check(imageVersion.contains(TARGET_VERSION)) {
                "Unexpected qemu-img version: ${imageVersion.lineSequence().firstOrNull().orEmpty()}"
            }
            runProbe(imageBinary, "--help")

            RuntimeState(
                available = true,
                status = "QEMU $TARGET_VERSION ready · $abi · system emulator and qemu-img verified",
                abi = abi
            ).also { currentState = it }
        } catch (error: Exception) {
            RuntimeState(
                available = false,
                status = "QEMU runtime unavailable: ${error.message ?: error.javaClass.simpleName}"
            ).also { currentState = it }
        }
    }

    fun systemBinary(context: Context): File =
        File(context.noBackupFilesDir, "qemu/${currentAbi()}/qemu-system-aarch64")

    fun imageBinary(context: Context): File =
        File(context.noBackupFilesDir, "qemu/${currentAbi()}/qemu-img")

    private fun currentAbi(): String =
        Build.SUPPORTED_ABIS.firstOrNull { it == "arm64-v8a" || it == "x86_64" }
            ?: error("Unsupported device ABI")

    private fun installAsset(context: Context, abi: String, name: String, directory: File): File {
        val destination = File(directory, name)
        val temporary = File(directory, "$name.tmp")
        context.assets.open("qemu/$abi/$name").use { input ->
            FileOutputStream(temporary).use { output -> input.copyTo(output) }
        }
        check(temporary.setExecutable(true, true)) { "Unable to mark $name executable" }
        if (destination.exists()) check(destination.delete()) { "Unable to replace the previous $name binary" }
        check(temporary.renameTo(destination)) { "Unable to install $name into app-private storage" }
        check(destination.canExecute()) { "$name is not executable" }
        return destination
    }

    private fun verifyElfMachine(binary: File, abi: String) {
        FileInputStream(binary).use { input ->
            val header = ByteArray(20)
            var offset = 0
            while (offset < header.size) {
                val count = input.read(header, offset, header.size - offset)
                check(count > 0) { "Truncated ELF header: ${binary.name}" }
                offset += count
            }
            check(
                header[0] == 0x7f.toByte() &&
                    header[1] == 'E'.code.toByte() &&
                    header[2] == 'L'.code.toByte() &&
                    header[3] == 'F'.code.toByte()
            ) { "Invalid ELF executable: ${binary.name}" }

            val machine = (header[18].toInt() and 0xff) or ((header[19].toInt() and 0xff) shl 8)
            val expectedMachine = if (abi == "arm64-v8a") 183 else 62
            check(machine == expectedMachine) {
                "ELF architecture mismatch for $abi in ${binary.name}"
            }
        }
    }

    private fun runProbe(binary: File, argument: String): String {
        val output = File.createTempFile("qemu-probe-", ".txt", binary.parentFile)
        try {
            val process = ProcessBuilder(binary.absolutePath, argument)
                .redirectErrorStream(true)
                .redirectOutput(output)
                .start()
            if (!process.waitFor(12, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                error("${binary.name} $argument timed out")
            }
            val text = output.readText()
            check(process.exitValue() == 0) {
                "${binary.name} $argument failed (${process.exitValue()}): ${text.take(500)}"
            }
            return text
        } finally {
            output.delete()
        }
    }
}
