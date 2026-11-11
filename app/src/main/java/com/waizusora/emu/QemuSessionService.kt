package com.waizusora.emu

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

enum class QemuSessionPhase { STOPPED, STARTING, RUNNING, STOPPING, FAILED }

data class QemuSessionSnapshot(
    val phase: QemuSessionPhase = QemuSessionPhase.STOPPED,
    val detail: String = "Belum ada proses QEMU."
)

/** Process state shared by the foreground service and Compose UI. */
object QemuSessionState {
    private val mutableState = kotlinx.coroutines.flow.MutableStateFlow(QemuSessionSnapshot())
    val state: kotlinx.coroutines.flow.StateFlow<QemuSessionSnapshot> = mutableState

    internal fun update(phase: QemuSessionPhase, detail: String) {
        mutableState.value = QemuSessionSnapshot(phase, detail)
    }
}

/**
 * Owns the QEMU process in a foreground service. The current UI action deliberately starts
 * a paused machine without guest media; a live QEMU process is not reported as a booted guest.
 */
class QemuSessionService : Service() {
    companion object {
        private const val ACTION_START = "com.waizusora.emu.action.START_QEMU"
        private const val ACTION_STOP = "com.waizusora.emu.action.STOP_QEMU"
        private const val EXTRA_ARGUMENTS = "qemu_arguments"
        private const val CHANNEL_ID = "qemu_session"
        private const val NOTIFICATION_ID = 9200
        private const val STOP_REQUEST_CODE = 9201
        private const val STARTUP_GRACE_SECONDS = 2L
        private const val STOP_GRACE_SECONDS = 5L

        fun startPausedProcess(context: Context) {
            val intent = Intent(context, QemuSessionService::class.java)
                .setAction(ACTION_START)
                .putStringArrayListExtra(
                    EXTRA_ARGUMENTS,
                    arrayListOf(
                        "-machine", "virt",
                        "-cpu", "max",
                        "-m", "512",
                        "-smp", "1",
                        "-display", "none",
                        "-serial", "none",
                        "-monitor", "none",
                        "-S"
                    )
                )
            ContextCompat.startForegroundService(context, intent)
        }

        fun stopProcess(context: Context) {
            context.startService(
                Intent(context, QemuSessionService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @Volatile private var process: Process? = null
    private var sessionJob: Job? = null
    @Volatile private var stopRequested = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopActiveSession()
            ACTION_START -> {
                ensureNotificationChannel()
                startAsForeground()
                if (sessionJob?.isActive != true) {
                    stopRequested = false
                    val arguments = intent.getStringArrayListExtra(EXTRA_ARGUMENTS).orEmpty()
                    sessionJob = serviceScope.launch { runSession(arguments) }
                }
            }
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private suspend fun runSession(arguments: List<String>) {
        var child: Process? = null
        var outputJob: Job? = null
        val outputTail = BoundedOutputTail()
        try {
            QemuSessionState.update(QemuSessionPhase.STARTING, "Memulai proses QEMU…")
            check(arguments.isNotEmpty()) { "Argumen QEMU kosong" }
            check(arguments.size <= 256 && arguments.all { it.length <= 4096 }) {
                "Daftar argumen QEMU melebihi batas aman"
            }

            val runtime = QemuRuntime.initialize(this)
            check(runtime.available) { runtime.status }
            val binary = QemuRuntime.systemBinary(this)
            check(binary.isFile && binary.canExecute()) {
                "Executable qemu-system-aarch64 tidak tersedia di penyimpanan privat"
            }

            val firmwareArguments = QemuRuntime.firmwareArguments(this@QemuSessionService)
            child = withContext(NonCancellable + Dispatchers.IO) {
                ProcessBuilder(listOf(binary.absolutePath) + arguments + firmwareArguments)
                    .directory(binary.parentFile)
                    .redirectErrorStream(true)
                    .start()
            }
            process = child
            val runningProcess = child
            outputJob = serviceScope.launch(Dispatchers.IO) {
                runningProcess.inputStream.use { input ->
                    val buffer = ByteArray(8192)
                    while (currentCoroutineContext().isActive) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        outputTail.append(buffer, count)
                    }
                }
            }

            val exitedDuringStartup = withContext(Dispatchers.IO) {
                runningProcess.waitFor(STARTUP_GRACE_SECONDS, TimeUnit.SECONDS)
            }
            if (exitedDuringStartup) {
                outputJob.join()
                error(
                    "QEMU berhenti saat startup (exit ${runningProcess.exitValue()}): " +
                        outputTail.asText().takeLast(1200)
                )
            }

            QemuSessionState.update(
                QemuSessionPhase.RUNNING,
                "Proses QEMU aktif. Guest Linux belum di-boot."
            )
            updateNotification("QEMU aktif · guest belum di-boot")

            val exitCode = withContext(Dispatchers.IO) { runningProcess.waitFor() }
            outputJob.join()
            persistOutputTail(outputTail)
            if (stopRequested) {
                QemuSessionState.update(QemuSessionPhase.STOPPED, "Proses QEMU dihentikan.")
            } else if (exitCode == 0) {
                QemuSessionState.update(QemuSessionPhase.STOPPED, "Proses QEMU selesai normal.")
            } else {
                QemuSessionState.update(
                    QemuSessionPhase.FAILED,
                    "QEMU berhenti dengan exit code $exitCode. Log terakhir disimpan privat."
                )
            }
        } catch (cancelled: CancellationException) {
            if (stopRequested) {
                QemuSessionState.update(QemuSessionPhase.STOPPED, "Proses QEMU dihentikan.")
            } else {
                QemuSessionState.update(QemuSessionPhase.FAILED, "Startup QEMU dibatalkan.")
            }
            throw cancelled
        } catch (error: Exception) {
            persistOutputTail(outputTail)
            QemuSessionState.update(
                QemuSessionPhase.FAILED,
                error.message ?: "QEMU gagal dimulai."
            )
        } finally {
            withContext(NonCancellable + Dispatchers.IO) {
                child?.let { running ->
                    if (running.isAlive) {
                        running.destroy()
                        if (!running.waitFor(STOP_GRACE_SECONDS, TimeUnit.SECONDS)) {
                            running.destroyForcibly()
                            running.waitFor(2, TimeUnit.SECONDS)
                        }
                    }
                }
            }
            withContext(NonCancellable) {
                outputJob?.cancelAndJoin()
                persistOutputTail(outputTail)
            }
            process = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun stopActiveSession() {
        stopRequested = true
        val running = process
        if (running == null) {
            sessionJob?.cancel()
            if (sessionJob == null) {
                QemuSessionState.update(QemuSessionPhase.STOPPED, "Tidak ada proses QEMU aktif.")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            return
        }

        QemuSessionState.update(QemuSessionPhase.STOPPING, "Menghentikan proses QEMU…")
        serviceScope.launch(Dispatchers.IO) {
            running.destroy()
            if (!running.waitFor(STOP_GRACE_SECONDS, TimeUnit.SECONDS)) {
                running.destroyForcibly()
                running.waitFor(2, TimeUnit.SECONDS)
            }
        }
    }

    private fun persistOutputTail(tail: BoundedOutputTail) {
        runCatching {
            val directory = java.io.File(noBackupFilesDir, "qemu").apply { mkdirs() }
            java.io.File(directory, "last-session.log").writeBytes(tail.toByteArray())
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "QEMU virtual machine",
                    NotificationManager.IMPORTANCE_LOW
                ).apply { description = "Status proses virtual machine Emu" }
            )
        }
    }

    private fun buildNotification(message: String): Notification {
        val stopIntent = Intent(this, QemuSessionService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            STOP_REQUEST_CODE,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("Emu · QEMU")
            .setContentText(message)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }

    private fun startAsForeground() {
        val notification = buildNotification("Menyiapkan runtime QEMU…")
        val serviceType = if (Build.VERSION.SDK_INT >= 34) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, serviceType)
    }

    private fun updateNotification(message: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(message))
    }

    override fun onDestroy() {
        stopRequested = true
        process?.destroyForcibly()
        serviceScope.cancel()
        super.onDestroy()
    }

    private class BoundedOutputTail(private val capacity: Int = 64 * 1024) {
        private val bytes = ByteArray(capacity)
        private var next = 0
        private var size = 0

        @Synchronized
        fun append(source: ByteArray, count: Int) {
            for (index in 0 until count) {
                bytes[next] = source[index]
                next = (next + 1) % capacity
                if (size < capacity) size++
            }
        }

        @Synchronized
        fun toByteArray(): ByteArray {
            val result = ByteArray(size)
            val start = if (size == capacity) next else 0
            for (index in 0 until size) result[index] = bytes[(start + index) % capacity]
            return result
        }

        fun asText(): String = toByteArray().toString(Charsets.UTF_8)
    }
}
