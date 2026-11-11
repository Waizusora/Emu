package com.waizusora.emu

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Installs and probes the ABI-specific QEMU executables bundled by the CI build.
 * Executables are checksum-verified and copied to app-private storage before execution.
 */
object QemuRuntime {
    init {\n        System.loadLibrary("emu-qemu")\n    }\n\n    private external fun nativePrepareAudio(): Boolean\n    private external fun nativeGetStatus(): String\n\n    const val TARGET_VERSION = "9.2.0"
    const val FIRMWARE_VERSION = "2026.08+ds-2"
    private const val FIRMWARE_ASSET_PATH = "firmware/edk2-$FIRMWARE_VERSION"
    private const val FIRMWARE_SIZE_BYTES = 64L * 1024L * 1024L
    private val executableNames = setOf("qemu-system-aarch64", "qemu-img")
    private val firmwareNames = setOf("AAVMF_CODE.fd", "AAVMF_VARS.fd")

    data class RuntimeState(val available: Boolean, val status: String, val abi: String? = null)

    @Volatile
    private var currentState = RuntimeState(false, "QEMU runtime has not been initialized")

    fun isAvailable(): Boolean = currentState.available
    fun status(): String = currentState.status

    suspend fun initialize(context: Context): RuntimeState = withContext(Dispatchers.IO) {
        try {
            check(nativePrepareAudio()) {\n                "SDL2 could not select the Android AAudio backend"\n            }\n            val sdlStatus = nativeGetStatus()\n            check(sdlStatus.contains("AAudio backend compiled")) {\n                "SDL2 was linked without its AAudio backend: $sdlStatus"\n            }\n\n            val appContext = context.applicationContext
            val abi = Build.SUPPORTED_ABIS.firstOrNull {
                it == "arm64-v8a" || it == "x86_64"
            } ?: error("This device ABI is not supported by the bundled QEMU runtime")

            val runtimeDirectory = File(appContext.noBackupFilesDir, "qemu/$TARGET_VERSION/$abi")
            check(runtimeDirectory.exists() || runtimeDirectory.mkdirs()) {
                "Unable to create the private QEMU runtime directory"
            }

            val checksums = readChecksums(appContext, abi)
            val systemBinary = installAsset(
                appContext, "qemu/$abi/qemu-system-aarch64", "qemu-system-aarch64", runtimeDirectory,
                checksums.getValue("qemu-system-aarch64"), executable = true
            )
            val imageBinary = installAsset(
                appContext, "qemu/$abi/qemu-img", "qemu-img", runtimeDirectory,
                checksums.getValue("qemu-img"), executable = true
            )
            val firmwareChecksums = readFirmwareChecksums(appContext)
            val firmwareDirectory = File(appContext.noBackupFilesDir, "firmware/edk2/$FIRMWARE_VERSION")
            check(firmwareDirectory.exists() || firmwareDirectory.mkdirs()) {
                "Unable to create the private UEFI firmware directory"
            }
            val firmwareCode = installAsset(
                appContext, "$FIRMWARE_ASSET_PATH/AAVMF_CODE.fd", "AAVMF_CODE.fd", firmwareDirectory,
                firmwareChecksums.getValue("AAVMF_CODE.fd"), executable = false
            )
            val firmwareVars = installAsset(
                appContext, "$FIRMWARE_ASSET_PATH/AAVMF_VARS.fd", "AAVMF_VARS.fd", firmwareDirectory,
                firmwareChecksums.getValue("AAVMF_VARS.fd"), executable = false
            )
            check(firmwareCode.length() == FIRMWARE_SIZE_BYTES && firmwareVars.length() == FIRMWARE_SIZE_BYTES) {
                "AAVMF CODE and VARS firmware must both be exactly 64 MiB"
            }
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
                status = "QEMU $TARGET_VERSION + AAVMF $FIRMWARE_VERSION ready · $abi · checksums, ELF and executable probes verified · $sdlStatus · AAudio selected for the next SDL audio initialization",
                abi = abi
            ).also { currentState = it }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            RuntimeState(
                available = false,
                status = "QEMU runtime unavailable: ${error.message ?: error.javaClass.simpleName}"
            ).also { currentState = it }
        }
    }

    fun systemBinary(context: Context): File =
        File(context.noBackupFilesDir, "qemu/$TARGET_VERSION/${currentAbi()}/qemu-system-aarch64")

    fun imageBinary(context: Context): File =
        File(context.noBackupFilesDir, "qemu/$TARGET_VERSION/${currentAbi()}/qemu-img")

    /** Returns read-only firmware code and a per-VM writable copy of the UEFI variable store. */
    suspend fun firmwareArguments(context: Context): List<String> = withContext(Dispatchers.IO) {
        check(currentState.available) { "QEMU and AAVMF runtime have not passed initialization" }
        val firmwareDirectory = File(context.noBackupFilesDir, "firmware/edk2/$FIRMWARE_VERSION")
        val code = File(firmwareDirectory, "AAVMF_CODE.fd")
        val template = File(firmwareDirectory, "AAVMF_VARS.fd")
        check(code.isFile && template.isFile && code.length() == FIRMWARE_SIZE_BYTES && template.length() == FIRMWARE_SIZE_BYTES) {
            "AAVMF firmware files are missing or have an unexpected size"
        }
        val vmDirectory = File(context.applicationContext.noBackupFilesDir, "vms/default")
        check(vmDirectory.exists() || vmDirectory.mkdirs()) { "Unable to create the default VM directory" }
        val vars = File(vmDirectory, "AAVMF_VARS.fd")
        if (!vars.exists()) {
            val temporary = File(vmDirectory, ".AAVMF_VARS-${System.nanoTime()}.tmp")
            try {
                FileInputStream(template).use { input ->
                    FileOutputStream(temporary).use { output ->
                        input.copyTo(output, 64 * 1024)
                        output.fd.sync()
                    }
                }
                check(temporary.length() == FIRMWARE_SIZE_BYTES) { "UEFI variable-store copy is incomplete" }
                check(temporary.renameTo(vars)) { "Unable to publish the writable UEFI variable store" }
            } finally {
                if (temporary.exists()) temporary.delete()
            }
        }
        check(vars.isFile && vars.length() == FIRMWARE_SIZE_BYTES) {
            "The VM writable UEFI variable store is invalid"
        }
        listOf(
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=${code.absolutePath}",
            "-drive", "if=pflash,format=raw,unit=1,file=${vars.absolutePath}"
        )
    }

    /**
     * Creates a sparse QCOW2 image in app-private storage and verifies its format and
     * virtual capacity with qemu-img info before publishing the final filename.
     */
    suspend fun createDiskImage(context: Context, requestedName: String, sizeGb: Long): File =
        withContext(Dispatchers.IO) {
            check(currentState.available) { "QEMU runtime has not passed its executable probes" }
            check(sizeGb in 1L..2048L) { "Disk capacity must be between 1 and 2048 GB" }
            val name = requestedName.trim()
            check(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,47}").matches(name)) {
                "Disk name may contain only letters, numbers, dot, underscore and hyphen"
            }

            val directory = File(context.applicationContext.noBackupFilesDir, "disks")
            check(directory.exists() || directory.mkdirs()) {
                "Unable to create the private virtual-disk directory"
            }
            val destination = File(directory, "$name.qcow2")
            check(!destination.exists()) { "A disk named $name.qcow2 already exists" }
            val temporary = File(directory, ".$name-${System.nanoTime()}.qcow2.tmp")
            val binary = imageBinary(context)
            check(binary.isFile && binary.canExecute()) {
                "qemu-img is not executable in app-private storage"
            }

            try {
                runImageTool(binary, listOf("create", "-f", "qcow2", "-o", "compat=1.1", temporary.absolutePath, "${sizeGb}G"), 120)
                check(temporary.isFile && temporary.length() > 0L) {
                    "qemu-img did not create a disk image"
                }

                val info = runImageTool(binary, listOf("info", "--output=json", temporary.absolutePath), 30)
                val metadata = JSONObject(info)
                check(metadata.optString("format") == "qcow2") {
                    "qemu-img produced an image that is not QCOW2"
                }
                val expectedBytes = Math.multiplyExact(sizeGb, 1024L * 1024L * 1024L)
                check(metadata.optLong("virtual-size", -1L) == expectedBytes) {
                    "QCOW2 virtual capacity does not match the requested size"
                }
                check(temporary.renameTo(destination)) {
                    "Unable to publish the verified QCOW2 image"
                }
                destination
            } finally {
                if (temporary.exists()) temporary.delete()
            }
        }

    private fun runImageTool(binary: File, arguments: List<String>, timeoutSeconds: Long): String {
        val output = File.createTempFile("qemu-img-", ".log", binary.parentFile)
        var process: Process? = null
        try {
            val started = ProcessBuilder(listOf(binary.absolutePath) + arguments)
                .directory(binary.parentFile)
                .redirectErrorStream(true)
                .redirectOutput(output)
                .start()
            process = started
            if (!started.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
                started.destroy()
                if (!started.waitFor(2, TimeUnit.SECONDS)) {
                    started.destroyForcibly()
                    started.waitFor(2, TimeUnit.SECONDS)
                }
                error("qemu-img timed out after $timeoutSeconds seconds")
            }
            val result = output.readText()
            check(started.exitValue() == 0) {
                "qemu-img failed (exit ${started.exitValue()}): ${result.take(1200)}"
            }
            return result
        } finally {
            process?.let {
                if (it.isAlive) {
                    it.destroyForcibly()
                    it.waitFor(2, TimeUnit.SECONDS)
                }
            }
            output.delete()
        }
    }

    private fun currentAbi(): String =
        Build.SUPPORTED_ABIS.firstOrNull { it == "arm64-v8a" || it == "x86_64" }
            ?: error("Unsupported device ABI")

    private fun readChecksums(context: Context, abi: String): Map<String, String> {
        val checksums = linkedMapOf<String, String>()
        context.assets.open("qemu/$abi/SHA256SUMS").bufferedReader().useLines { lines ->
            lines.forEach { line ->
                val match = Regex("""^([0-9a-f]{64})\s+\*?(qemu-system-aarch64|qemu-img)$""")
                    .matchEntire(line.trim())
                    ?: error("Invalid QEMU checksum manifest entry for $abi")
                val name = match.groupValues[2]
                check(checksums.put(name, match.groupValues[1]) == null) {
                    "Duplicate checksum manifest entry: $name"
                }
            }
        }
        check(checksums.keys == executableNames) {
            "QEMU checksum manifest is incomplete for $abi"
        }
        return checksums
    }

    private fun readFirmwareChecksums(context: Context): Map<String, String> {
        val checksums = linkedMapOf<String, String>()
        context.assets.open("$FIRMWARE_ASSET_PATH/SHA256SUMS").bufferedReader().useLines { lines ->
            lines.forEach { line ->
                val fields = line.trim().split(Regex("\\s+"), limit = 2)
                check(fields.size == 2 && fields[0].matches(Regex("[0-9a-f]{64}"))) {
                    "Invalid AAVMF checksum manifest entry"
                }
                val name = fields[1].removePrefix("*")
                check(name in firmwareNames && checksums.put(name, fields[0]) == null) {
                    "Invalid or duplicate AAVMF checksum entry: $name"
                }
            }
        }
        check(checksums.keys == firmwareNames) { "AAVMF checksum manifest is incomplete" }
        return checksums
    }

    private fun installAsset(
        context: Context,
        assetPath: String,
        name: String,
        directory: File,
        expectedSha256: String,
        executable: Boolean
    ): File {
        val destination = File(directory, name)
        val temporary = File(directory, "$name.tmp")
        if (destination.isFile && (!executable || destination.canExecute()) && sha256(destination) == expectedSha256) {
            return destination
        }

        try {
            val digest = MessageDigest.getInstance("SHA-256")
            context.assets.open(assetPath).use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            check(toHex(digest.digest()) == expectedSha256) {
                "SHA-256 mismatch for $assetPath"
            }
            if (executable) check(temporary.setExecutable(true, true)) { "Unable to mark $name executable" }
            if (destination.exists()) {
                check(destination.delete()) { "Unable to replace the previous $name binary" }
            }
            check(temporary.renameTo(destination)) {
                "Unable to install $name into app-private storage"
            }
            if (executable) check(destination.canExecute()) { "$name is not executable" }
            return destination
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return toHex(digest.digest())
    }

    private fun toHex(bytes: ByteArray): String =
        bytes.joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private fun verifyElfMachine(binary: File, abi: String) {
        FileInputStream(binary).use { input ->
            val header = ByteArray(64)
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
            check(header[4] == 2.toByte() && header[5] == 1.toByte()) {
                "Expected a 64-bit little-endian ELF executable: ${binary.name}"
            }
            val elfType = (header[16].toInt() and 0xff) or ((header[17].toInt() and 0xff) shl 8)
            check(elfType == 3) { "Expected a position-independent executable: ${binary.name}" }

            val machine = (header[18].toInt() and 0xff) or ((header[19].toInt() and 0xff) shl 8)
            val expectedMachine = if (abi == "arm64-v8a") 183 else 62
            check(machine == expectedMachine) {
                "ELF architecture mismatch for $abi in ${binary.name}"
            }
        }
    }

    private fun runProbe(binary: File, argument: String): String {
        val output = File.createTempFile("qemu-probe-", ".txt", binary.parentFile)
        var process: Process? = null
        try {
            val startedProcess = ProcessBuilder(binary.absolutePath, argument)
                .directory(binary.parentFile)
                .redirectErrorStream(true)
                .redirectOutput(output)
                .start()
            process = startedProcess
            if (!startedProcess.waitFor(12, TimeUnit.SECONDS)) {
                startedProcess.destroyForcibly()
                startedProcess.waitFor(2, TimeUnit.SECONDS)
                error("${binary.name} $argument timed out")
            }
            val text = output.readText()
            check(startedProcess.exitValue() == 0) {
                "${binary.name} $argument failed (${startedProcess.exitValue()}): ${text.take(500)}"
            }
            return text
        } finally {
            process?.let {
                if (it.isAlive) {
                    it.destroyForcibly()
                    it.waitFor(2, TimeUnit.SECONDS)
                }
            }
            output.delete()
        }
    }
}
