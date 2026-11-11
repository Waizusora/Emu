package com.waizusora.emu

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Describes one component that is actually packaged in the current APK. */
private data class OpenSourceNotice(
    val name: String,
    val summary: String,
    val copyright: String,
    val licenseName: String,
    val licenseAsset: String
)

/**
 * Displays APK attributions and complete bundled license texts.
 * QEMU and AAVMF firmware are staged into the APK by the CI build.
 */
@Composable
internal fun OpenSourceNoticesScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    var selectedNotice by remember { mutableStateOf<OpenSourceNotice?>(null) }

    // Keep the catalog limited to app/runtime libraries packaged in this APK.
    val notices = remember {
        listOf(
            OpenSourceNotice(
                name = "Emu",
                summary = "Android application, Jetpack Compose screens, and JNI bridge.",
                copyright = "Copyright (c) 2026 Waizusora",
                licenseName = "MIT License",
                licenseAsset = "licenses/mit.txt"
            ),
            OpenSourceNotice(
                name = "AndroidX and Jetpack Compose",
                summary = "Android core extensions, Activity integration, lifecycle APIs, Compose UI, and Material 3.",
                copyright = "Copyright Google LLC and The Android Open Source Project contributors.",
                licenseName = "Apache License 2.0",
                licenseAsset = "licenses/apache-2.0.txt"
            ),
            OpenSourceNotice(
                name = "Kotlin",
                summary = "Kotlin language and standard runtime used by the Android application.",
                copyright = "Copyright JetBrains s.r.o. and Kotlin Programming Language contributors.",
                licenseName = "Apache License 2.0",
                licenseAsset = "licenses/apache-2.0.txt"
            ),
            OpenSourceNotice(
                name = "AAVMF / EDK II UEFI firmware",
                summary = "AArch64 UEFI firmware for QEMU virt machines, packaged from Debian qemu-efi-aarch64 2026.08+ds-2.",
                copyright = "Copyright the EDK II contributors and individual copyright holders listed in Debian’s package copyright file.",
                licenseName = "Debian copyright and license notices (multiple components)",
                licenseAsset = "licenses/edk2-aarch64-copyright.txt"
            )
        )
    }

    // Read license files from APK assets so notices work offline and remain version-matched.
    val licenseText = remember(selectedNotice) {
        selectedNotice?.let { entry ->
            runCatching {
                context.assets.open(entry.licenseAsset).bufferedReader().use { it.readText() }
            }.getOrElse { "License text is unavailable in this application package." }
        }.orEmpty()
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = {
                    if (selectedNotice == null) onBack() else selectedNotice = null
                }) {
                    Text(if (selectedNotice == null) "Back to Settings" else "Back to notices")
                }
            }
            Text(
                selectedNotice?.name ?: "Open source notices",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold
            )
            Text(
                selectedNotice?.summary ?: "Components and license texts included in this APK.",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        if (selectedNotice == null) {
            items(notices) { entry ->
                // Each card opens its own attribution and license detail view.
                Card(
                    onClick = { selectedNotice = entry },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp)
                ) {
                    Column(
                        Modifier.fillMaxWidth().padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(entry.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(entry.summary, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(entry.licenseName, style = MaterialTheme.typography.labelLarge)
                        Text("View license  ›", color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
            item {
                Card(shape = RoundedCornerShape(18.dp)) {
                    Column(
                        Modifier.fillMaxWidth().padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("QEMU 9.2.0", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(
                            "QEMU is the full-system machine emulator for AArch64 Linux guests. CI stages qemu-system-aarch64 and qemu-img for arm64-v8a and x86_64 into this APK; the runtime copies them into app-private storage and verifies their SHA-256 checksums and ELF architecture before execution. QEMU is licensed under GPL-2.0; its license, corresponding source, and notices for incorporated dependencies must accompany distributed builds.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text("Included in this APK", style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
        } else {
            item {
                Card(shape = RoundedCornerShape(18.dp)) {
                    Column(
                        Modifier.fillMaxWidth().padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text("Copyright", fontWeight = FontWeight.SemiBold)
                        Text(selectedNotice?.copyright.orEmpty())
                        Text("License", fontWeight = FontWeight.SemiBold)
                        Text(selectedNotice?.licenseName.orEmpty())
                    }
                }
                Text(
                    licenseText,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                )
            }
        }
    }
}
