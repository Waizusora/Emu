package com.waizusora.emu

import android.app.Activity
import android.Manifest
import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.Bundle
import android.os.StatFs
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.waizusora.emu.ui.theme.EmuTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.TimeUnit

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { EmuTheme { EmuApp() } }
    }
}

private enum class AppTab(val title: String, val symbol: String) {
    Home("Home", "⌂"), Storage("Storage", "▤"), Settings("Settings", "⚙")
}

/**
 * Imports Android document URIs into app-private storage without buffering whole images in RAM.
 * ISO files are checked for an ISO 9660 primary volume descriptor; disks must be self-contained
 * QCOW2 images whose metadata can be read by the bundled qemu-img executable.
 */
private object MediaImporter {
    private const val COPY_BUFFER_SIZE = 64 * 1024
    private const val MAX_DISK_BYTES = 2048L * 1024L * 1024L * 1024L

    suspend fun importIso(context: Context, uri: Uri): File =
        importFile(context, uri, "isos", "iso", ::validateIso)

    suspend fun importDisk(context: Context, uri: Uri): File =
        importFile(context, uri, "disks", "qcow2") { file -> validateDisk(context, file) }

    private suspend fun importFile(
        context: Context,
        uri: Uri,
        directoryName: String,
        extension: String,
        validate: (File) -> Unit
    ): File = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val resolver = appContext.contentResolver
        val metadata = resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null
        )?.use { cursor ->
            if (!cursor.moveToFirst()) null else {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                val name = if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    cursor.getString(nameIndex)
                } else {
                    null
                }
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    cursor.getLong(sizeIndex)
                } else {
                    null
                }
                name to size
            }
        }
        val sourceName = metadata?.first ?: uri.lastPathSegment ?: "imported"
        val declaredSize = metadata?.second
        val directory = File(appContext.noBackupFilesDir, directoryName)
        check(directory.exists() || directory.mkdirs()) {
            "Unable to create private " + directoryName + " directory"
        }

        val baseName = safeBaseName(sourceName)
        var destination = File(directory, baseName + "." + extension)
        var suffix = 1
        while (destination.exists()) {
            destination = File(directory, baseName + "-" + suffix + "." + extension)
            suffix++
        }
        val temporary = File(directory, ".import-" + UUID.randomUUID() + ".part")

        try {
            val input = resolver.openInputStream(uri)
                ?: error("Android could not open the selected document")
            var copiedBytes = 0L
            input.use { source ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(COPY_BUFFER_SIZE)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = source.read(buffer)
                        if (count < 0) break
                        copiedBytes = Math.addExact(copiedBytes, count.toLong())
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            check(copiedBytes > 0L) { "The selected document is empty" }
            if (declaredSize != null && declaredSize >= 0L) {
                check(copiedBytes == declaredSize) {
                    "Imported byte count does not match the document provider's reported size"
                }
            }
            check(temporary.isFile && temporary.length() == copiedBytes) {
                "The imported file size could not be verified"
            }

            validate(temporary)
            check(temporary.renameTo(destination)) {
                "Unable to publish the verified file in app-private storage"
            }
            destination
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun safeBaseName(displayName: String): String {
        val leaf = displayName.substringAfterLast('/').substringAfterLast('\\')
        val base = leaf.substringBeforeLast('.', leaf)
            .replace(Regex("[^A-Za-z0-9._-]+"), "-")
            .trim('.', '-', '_')
            .take(48)
        return base.ifBlank { "imported" }
    }

    private fun validateIso(file: File) {
        val descriptorOffset = 16L * 2048L
        check(file.length() >= descriptorOffset + 7L) {
            "ISO image is too small to contain an ISO 9660 volume descriptor"
        }
        RandomAccessFile(file, "r").use { image ->
            image.seek(descriptorOffset)
            val descriptor = ByteArray(7)
            image.readFully(descriptor)
            val identifier = String(descriptor, 1, 5, Charsets.US_ASCII)
            check(
                descriptor[0].toInt() == 1 &&
                    identifier == "CD001" &&
                    descriptor[6].toInt() == 1
            ) {
                "Selected file does not contain a valid ISO 9660 primary volume descriptor"
            }
        }
    }

    private fun validateDisk(context: Context, file: File) {
        val binary = QemuRuntime.imageBinary(context)
        check(binary.isFile && binary.canExecute()) {
            "Bundled qemu-img is not executable; disk validation is unavailable"
        }
        val log = File.createTempFile("qemu-img-import-", ".log", binary.parentFile)
        var process: Process? = null
        try {
            val started = ProcessBuilder(
                binary.absolutePath,
                "info",
                "--output=json",
                file.absolutePath
            ).directory(binary.parentFile)
                .redirectErrorStream(true)
                .redirectOutput(log)
                .start()
            process = started
            if (!started.waitFor(30, TimeUnit.SECONDS)) {
                started.destroy()
                if (!started.waitFor(2, TimeUnit.SECONDS)) {
                    started.destroyForcibly()
                    started.waitFor(2, TimeUnit.SECONDS)
                }
                error("qemu-img info timed out while validating the imported disk")
            }
            val output = log.readText()
            check(started.exitValue() == 0) {
                "qemu-img rejected the imported disk (exit " + started.exitValue() +
                    "): " + output.take(1000)
            }
            val metadata = JSONObject(output)
            check(metadata.optString("format") == "qcow2") {
                "Only QCOW2 disk images are currently supported for import"
            }
            check(metadata.optString("backing-filename").isBlank()) {
                "QCOW2 images with external backing files cannot be imported"
            }
            check(metadata.optString("data-file").isBlank()) {
                "QCOW2 images with external data files cannot be imported"
            }
            val virtualSize = metadata.optLong("virtual-size", -1L)
            check(virtualSize in 1L..MAX_DISK_BYTES) {
                "QCOW2 virtual capacity must be between 1 byte and 2048 GiB"
            }
            check(file.length() > 0L) { "Imported QCOW2 image is empty" }
        } finally {
            process?.let {
                if (it.isAlive) {
                    it.destroyForcibly()
                    it.waitFor(2, TimeUnit.SECONDS)
                }
            }
            log.delete()
        }
    }
}

@Composable
private fun EmuApp() {
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    var runtimeAvailable by remember { mutableStateOf(false) }
    var runtimeStatus by remember { mutableStateOf("Preparing QEMU 9.2.0 runtime…") }
    var runtimeInitialized by remember { mutableStateOf(false) }
    val qemuSession by QemuSessionState.state.collectAsState()
    LaunchedEffect(Unit) {
        val runtime = QemuRuntime.initialize(context)
        runtimeAvailable = runtime.available
        runtimeStatus = runtime.status
        runtimeInitialized = true
    }
    var selectedTab by remember { mutableIntStateOf(0) }
    // Keep the notices page inside Settings so users can return without changing app navigation.
    var showOpenSourceNotices by remember { mutableStateOf(false) }
    var selectedIso by remember { mutableStateOf<Uri?>(null) }
    var selectedDisk by remember { mutableStateOf<Uri?>(null) }
    var orientationLock by remember { mutableStateOf(false) }
    var diskName by remember { mutableStateOf("linux-disk") }
    var diskSize by remember { mutableStateOf("16") }
    var diskOperationBusy by remember { mutableStateOf(false) }
    var mediaImportBusy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf("No image selected yet.") }
    // Show a one-time onboarding explanation before asking the user to open system permission screens.
    val preferences = remember { context.getSharedPreferences("emu_preferences", Context.MODE_PRIVATE) }
    var showOnboarding by remember { mutableStateOf(!preferences.getBoolean("onboarding_complete", false)) }
    var permissionRefresh by remember { mutableIntStateOf(0) }
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { permissionRefresh++ }

    val notificationsGranted = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
        android.content.pm.PackageManager.PERMISSION_GRANTED
    val batteryOptimizationExempt = remember(permissionRefresh) {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && !notificationsGranted) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    fun openBatteryOptimizationSettings() {
        // Android owns the exemption prompt; users must explicitly approve it.
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${context.packageName}")
            }
        } else {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        }
        runCatching { context.startActivity(intent) }
    }

    LaunchedEffect(orientationLock) {
        (context as? Activity)?.requestedOrientation = if (orientationLock) {
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    fun importSelectedMedia(uri: Uri, isIso: Boolean) {
        if (mediaImportBusy) return
        mediaImportBusy = true
        notice = if (isIso) "Importing and validating ISO…" else "Importing and validating QCOW2 disk…"
        coroutineScope.launch {
            try {
                runCatching {
                    context.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
                val imported = if (isIso) {
                    MediaImporter.importIso(context, uri)
                } else {
                    MediaImporter.importDisk(context, uri)
                }
                if (isIso) {
                    selectedIso = Uri.fromFile(imported)
                    notice = "ISO imported and validated: " + imported.name +
                        " (" + imported.length() + " bytes), stored privately."
                } else {
                    selectedDisk = Uri.fromFile(imported)
                    notice = "QCOW2 imported and validated: " + imported.name +
                        " (" + imported.length() + " bytes), stored privately."
                }
                selectedTab = 1
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                notice = (if (isIso) "ISO import failed: " else "Disk import failed: ") +
                    (error.message ?: error.javaClass.simpleName)
            } finally {
                mediaImportBusy = false
            }
        }
    }

    val isoPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importSelectedMedia(uri, true)
    }
    val diskPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importSelectedMedia(uri, false)
    }

    if (showOnboarding) {
        AlertDialog(
            onDismissRequest = {
                preferences.edit().putBoolean("onboarding_complete", true).apply()
                showOnboarding = false
            },
            title = { Text("Selamat datang di Emu") },
            text = {
                Text(
                    "Emu menjalankan sistem Linux virtual melalui QEMU. Pilih ISO dan disk melalui pemilih file Android. " +
                    "Jika sesi VM berjalan, notifikasi foreground membantu menunjukkan aktivitasnya. " +
                    "Anda dapat mengizinkan notifikasi dan mengecualikan Emu dari optimasi baterai. " +
                    "Android tetap dapat menghentikan aplikasi saat force stop, tekanan memori, atau pembatasan sistem."
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    // Request the runtime notification permission only after the user taps this button.
                    requestNotificationPermission()
                    preferences.edit().putBoolean("onboarding_complete", true).apply()
                    showOnboarding = false
                }) { Text("Atur izin") }
            },
            dismissButton = {
                TextButton(onClick = {
                    preferences.edit().putBoolean("onboarding_complete", true).apply()
                    showOnboarding = false
                }) { Text("Nanti") }
            }
        )
    }

    Scaffold(bottomBar = {
        NavigationBar {
            AppTab.entries.forEachIndexed { index, tab ->
                NavigationBarItem(
                    selected = selectedTab == index,
                    onClick = { selectedTab = index },
                    icon = { Text(tab.symbol) },
                    label = { Text(tab.title) }
                )
            }
        }
    }) { padding ->
        Surface(
            modifier = Modifier.fillMaxSize().padding(padding),
            color = MaterialTheme.colorScheme.background
        ) {
            when (AppTab.entries[selectedTab]) {
                AppTab.Home -> HomeScreen(
                    hasMedia = selectedIso != null || selectedDisk != null,
                    notice = notice,
                    runtimeStatus = runtimeStatus,
                    runtimeAvailable = runtimeAvailable,
                    runtimeInitialized = runtimeInitialized,
                    session = qemuSession,
                    onStartSession = { QemuSessionService.startPausedProcess(context) },
                    onStopSession = { QemuSessionService.stopProcess(context) },
                    mediaImportBusy = mediaImportBusy,
                    onChooseIso = { if (!mediaImportBusy) isoPicker.launch(arrayOf("application/x-iso9660-image", "*/*")) },
                    onChooseDisk = { if (!mediaImportBusy) diskPicker.launch(arrayOf("application/octet-stream", "*/*")) }
                )
                AppTab.Storage -> StorageScreen(
                    selectedIso = selectedIso,
                    selectedDisk = selectedDisk,
                    mediaImportBusy = mediaImportBusy,
                    onChooseIso = { if (!mediaImportBusy) isoPicker.launch(arrayOf("application/x-iso9660-image", "*/*")) },
                    onChooseDisk = { if (!mediaImportBusy) diskPicker.launch(arrayOf("application/octet-stream", "*/*")) }
                )
                AppTab.Settings -> if (showOpenSourceNotices) {
                    OpenSourceNoticesScreen(onBack = { showOpenSourceNotices = false })
                } else {
                    SettingsScreen(
                        orientationLock = orientationLock,
                        onOrientationChange = { orientationLock = it },
                        diskName = diskName,
                        onDiskNameChange = { diskName = it },
                        diskSize = diskSize,
                        onDiskSizeChange = { diskSize = it },
                        onCreateDisk = {
                            val capacityGb = diskSize.toLongOrNull()
                            if (!runtimeInitialized || !runtimeAvailable) {
                                notice = "QEMU runtime is not ready; QCOW2 creation is disabled."
                            } else if (capacityGb == null || capacityGb !in 1L..2048L) {
                                notice = "Disk capacity must be between 1 and 2048 GB."
                            } else if (!diskOperationBusy) {
                                diskOperationBusy = true
                                notice = "Creating and verifying QCOW2 image…"
                                coroutineScope.launch {
                                    try {
                                        val image = QemuRuntime.createDiskImage(context, diskName, capacityGb)
                                        selectedDisk = Uri.fromFile(image)
                                        notice = "QCOW2 created and verified: ${image.name} (${capacityGb} GB virtual capacity). Stored in app-private storage."
                                        selectedTab = 1
                                    } catch (error: Exception) {
                                        notice = "QCOW2 creation failed: ${error.message ?: error.javaClass.simpleName}"
                                    } finally {
                                        diskOperationBusy = false
                                    }
                                }
                            }
                        },
                        diskOperationBusy = diskOperationBusy,
                        runtimeAvailable = runtimeInitialized && runtimeAvailable,
                        notice = notice,
                        notificationsGranted = notificationsGranted,
                        batteryOptimizationExempt = batteryOptimizationExempt,
                        onRequestNotifications = { requestNotificationPermission() },
                        onRequestBatteryExemption = { openBatteryOptimizationSettings() },
                        onOpenSourceNotices = { showOpenSourceNotices = true }
                    )
                }
            }
        }
    }
}

@Composable
private fun HomeScreen(
    hasMedia: Boolean,
    notice: String,
    runtimeStatus: String,
    runtimeAvailable: Boolean,
    runtimeInitialized: Boolean,
    session: QemuSessionSnapshot,
    mediaImportBusy: Boolean,
    onStartSession: () -> Unit,
    onStopSession: () -> Unit,
    onChooseIso: () -> Unit,
    onChooseDisk: () -> Unit
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        item {
            Spacer(Modifier.height(18.dp))
            Text("Emu", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text("Linux virtual machines on Android", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        item {
            Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Virtual machines", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("No virtual machines yet", style = MaterialTheme.typography.titleMedium)
                    Text("Select installation media and a virtual disk to prepare a guest system.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(
                        onClick = onChooseIso,
                        enabled = !mediaImportBusy,
                        modifier = Modifier.fillMaxWidth()
                    ) { Text(if (mediaImportBusy) "Importing media…" else "Choose installation ISO") }
                    OutlinedButton(
                        onClick = onChooseDisk,
                        enabled = !mediaImportBusy,
                        modifier = Modifier.fillMaxWidth()
                    ) { Text("Choose QCOW2 disk") }
                }
            }
        }
        item {
            Card(shape = RoundedCornerShape(20.dp)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Status", fontWeight = FontWeight.SemiBold)
                    Text(if (hasMedia) "Media selected" else "Ready for setup")
                    Text(notice, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item {
            Text(
                when {
                    !runtimeInitialized -> "QEMU 9.2.0 · checking runtime"
                    runtimeAvailable -> "QEMU 9.2.0 · runtime verified"
                    else -> "QEMU 9.2.0 · runtime unavailable"
                },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium
            )
            Text(runtimeStatus, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
        item {
            Card(shape = RoundedCornerShape(20.dp)) {
                Column(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("QEMU process", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        session.detail,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall
                    )
                    when (session.phase) {
                        QemuSessionPhase.STOPPED, QemuSessionPhase.FAILED -> Button(
                            onClick = onStartSession,
                            enabled = runtimeInitialized && runtimeAvailable,
                            modifier = Modifier.fillMaxWidth()
                        ) { Text(if (session.phase == QemuSessionPhase.FAILED) "Retry QEMU process" else "Start QEMU paused (no guest)") }
                        QemuSessionPhase.RUNNING -> OutlinedButton(
                            onClick = onStopSession,
                            modifier = Modifier.fillMaxWidth()
                        ) { Text("Stop QEMU") }
                        QemuSessionPhase.STARTING -> Text("Starting QEMU…")
                        QemuSessionPhase.STOPPING -> Text("Stopping QEMU…")
                    }
                    Text(
                        "This lifecycle check starts QEMU with its virtual CPU paused and no guest media. It does not boot Linux.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }
        }
    }
}

@Composable
private fun StorageScreen(
    selectedIso: Uri?,
    selectedDisk: Uri?,
    mediaImportBusy: Boolean,
    onChooseIso: () -> Unit,
    onChooseDisk: () -> Unit
) {
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Spacer(Modifier.height(4.dp))
        Text("Storage", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text("Files are selected through Android's system document picker.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        Card(shape = RoundedCornerShape(20.dp)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Installation media", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(selectedIso?.lastPathSegment ?: "No ISO selected", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("ISO images are used to boot an installer or live environment.")
                OutlinedButton(
                    onClick = onChooseIso,
                    enabled = !mediaImportBusy,
                    modifier = Modifier.fillMaxWidth()
                ) { Text(if (mediaImportBusy) "Importing…" else "Import ISO file") }
            }
        }
        Card(shape = RoundedCornerShape(20.dp)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Virtual hard disk", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(selectedDisk?.lastPathSegment ?: "No QCOW2 selected", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("QCOW2 files store the guest operating system and data.")
                OutlinedButton(
                    onClick = onChooseDisk,
                    enabled = !mediaImportBusy,
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Import QCOW2 file") }
            }
        }
    }
}

@Composable
private fun SettingsScreen(
    orientationLock: Boolean,
    onOrientationChange: (Boolean) -> Unit,
    diskName: String,
    onDiskNameChange: (String) -> Unit,
    diskSize: String,
    onDiskSizeChange: (String) -> Unit,
    onCreateDisk: () -> Unit,
    diskOperationBusy: Boolean,
    runtimeAvailable: Boolean,
    notice: String,
    notificationsGranted: Boolean,
    batteryOptimizationExempt: Boolean,
    onRequestNotifications: () -> Unit,
    onRequestBatteryExemption: () -> Unit,
    onOpenSourceNotices: () -> Unit
) {
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Spacer(Modifier.height(18.dp))
            Text("Settings", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text("App preferences and virtual disk tools.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        item {
            Card(shape = RoundedCornerShape(20.dp)) {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Lock landscape orientation", fontWeight = FontWeight.SemiBold)
                        Text("Prefer landscape while using a VM.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    }
                    Switch(checked = orientationLock, onCheckedChange = onOrientationChange)
                }
            }
        }
        item {
            Card(shape = RoundedCornerShape(20.dp)) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Virtual disks", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("Create a QCOW2 disk image")
                    OutlinedTextField(value = diskName, onValueChange = onDiskNameChange, label = { Text("Disk name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(value = diskSize, onValueChange = onDiskSizeChange, label = { Text("Capacity (GB)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    Button(
                        onClick = onCreateDisk,
                        modifier = Modifier.fillMaxWidth(),
                        enabled = runtimeAvailable && !diskOperationBusy &&
                            Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,47}").matches(diskName.trim()) &&
                            (diskSize.toLongOrNull() ?: 0L) in 1L..2048L
                    ) {
                        Text(if (diskOperationBusy) "Creating QCOW2…" else "Create QCOW2")
                    }
                    Text(
                        "Creates a sparse QCOW2 image with qemu-img, verifies its format and virtual capacity, then stores it in app-private storage. Capacity: 1–2048 GB.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }
        }
        item {
            Card(shape = RoundedCornerShape(20.dp)) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Background operation", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (notificationsGranted) "Notifications: allowed" else "Notifications: not allowed",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedButton(onClick = onRequestNotifications, modifier = Modifier.fillMaxWidth()) {
                        Text("Allow notifications")
                    }
                    Text(
                        if (batteryOptimizationExempt) "Battery optimization: exempt" else "Battery optimization: enabled",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedButton(onClick = onRequestBatteryExemption, modifier = Modifier.fillMaxWidth()) {
                        Text("Open battery exemption settings")
                    }
                    Text(
                        "Battery exemption reduces Doze restrictions but does not prevent force-stop, OEM task killers, or low-memory termination. A foreground service with a persistent notification is required while a VM is running.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
        item {
            // Provide a direct, tappable entry to the bundled license and attribution catalog.
            Card(onClick = onOpenSourceNotices, shape = RoundedCornerShape(20.dp)) {
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Open source notices", fontWeight = FontWeight.SemiBold)
                        Text(
                            "View included components, copyright and full license texts.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    Text("›", style = MaterialTheme.typography.headlineMedium)
                }
            }
        }
        item {
            Text(notice, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(8.dp))
        }
    }
}
