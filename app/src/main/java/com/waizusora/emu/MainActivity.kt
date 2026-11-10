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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.waizusora.emu.ui.theme.EmuTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { EmuTheme { EmuApp() } }
    }
}

private enum class AppTab(val title: String, val symbol: String) {
    Home("Home", "⌂"), Storage("Storage", "▤"), Settings("Settings", "⚙")
}

@Composable
private fun EmuApp() {
    val context = LocalContext.current
    var selectedTab by remember { mutableIntStateOf(0) }
    var selectedIso by remember { mutableStateOf<Uri?>(null) }
    var selectedDisk by remember { mutableStateOf<Uri?>(null) }
    var orientationLock by remember { mutableStateOf(false) }
    var diskName by remember { mutableStateOf("linux-disk") }
    var diskSize by remember { mutableStateOf("16") }
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

    val isoPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            selectedIso = uri
            notice = "ISO selected: ${uri.lastPathSegment ?: "installation media"}"
        }
    }
    val diskPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            selectedDisk = uri
            notice = "Disk selected: ${uri.lastPathSegment ?: "virtual disk"}"
        }
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
                    runtimeStatus = QemuRuntime.status(),
                    runtimeAvailable = QemuRuntime.isAvailable(),
                    onChooseIso = { isoPicker.launch(arrayOf("application/x-iso9660-image", "*/*")) },
                    onChooseDisk = { diskPicker.launch(arrayOf("application/octet-stream", "*/*")) }
                )
                AppTab.Storage -> StorageScreen(
                    selectedIso = selectedIso,
                    selectedDisk = selectedDisk,
                    onChooseIso = { isoPicker.launch(arrayOf("application/x-iso9660-image", "*/*")) },
                    onChooseDisk = { diskPicker.launch(arrayOf("application/octet-stream", "*/*")) }
                )
                AppTab.Settings -> SettingsScreen(
                    orientationLock = orientationLock,
                    onOrientationChange = { orientationLock = it },
                    diskName = diskName,
                    onDiskNameChange = { diskName = it },
                    diskSize = diskSize,
                    onDiskSizeChange = { diskSize = it },
                    onCreateDisk = { notice = "QCOW2 creation requires the QEMU qemu-img runtime, which is not integrated yet." },
                    notice = notice,
                    notificationsGranted = notificationsGranted,
                    batteryOptimizationExempt = batteryOptimizationExempt,
                    onRequestNotifications = { requestNotificationPermission() },
                    onRequestBatteryExemption = { openBatteryOptimizationSettings() }
                )
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
                    Button(onClick = onChooseIso, modifier = Modifier.fillMaxWidth()) { Text("Choose installation ISO") }
                    OutlinedButton(onClick = onChooseDisk, modifier = Modifier.fillMaxWidth()) { Text("Choose QCOW2 disk") }
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
            Text(if (runtimeAvailable) "QEMU 9.2.0 · TCG ready" else "QEMU 9.2.0 · runtime unavailable", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
            Text(runtimeStatus, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun StorageScreen(
    selectedIso: Uri?,
    selectedDisk: Uri?,
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
                OutlinedButton(onClick = onChooseIso, modifier = Modifier.fillMaxWidth()) { Text("Choose ISO file") }
            }
        }
        Card(shape = RoundedCornerShape(20.dp)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Virtual hard disk", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(selectedDisk?.lastPathSegment ?: "No QCOW2 selected", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("QCOW2 files store the guest operating system and data.")
                OutlinedButton(onClick = onChooseDisk, modifier = Modifier.fillMaxWidth()) { Text("Choose QCOW2 file") }
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
    notice: String,
    notificationsGranted: Boolean,
    batteryOptimizationExempt: Boolean,
    onRequestNotifications: () -> Unit,
    onRequestBatteryExemption: () -> Unit
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
                        enabled = diskName.isNotBlank() && (diskSize.toLongOrNull() ?: 0L) > 0L
                    ) { Text("Create QCOW2") }
                    Text("Disk creation will call QEMU qemu-img. Native runtime integration is pending.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
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
            Text(notice, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(8.dp))
        }
    }
}
