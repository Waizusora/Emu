# Emu

Emu is an Android GUI for managing full-system Linux virtual machines using QEMU.
The project targets AArch64 guests and Android devices with `arm64-v8a` or
`x86_64` host ABIs. It does not bundle a Linux distribution; users provide
their own installation ISO and virtual disk images.

## Current status

The Android application includes:

- Kotlin and Jetpack Compose with Material 3.
- Home, Storage, and Settings navigation.
- System document picker flows for selecting ISO and QCOW2 files.
- Persistable read access for user-selected document URIs where supported.
- A landscape-orientation preference.
- An Android JNI library built with the NDK and CMake for both supported ABIs.
- A native runtime capability API that reports whether the QEMU engine is
  actually present; the current native bridge deliberately reports unavailable.

**QEMU 9.2.0 is cross-built successfully by CI for `arm64-v8a` and `x86_64`, but its binaries are not yet packaged in the APK.** CI uploads the emulator and `qemu-img` as separate build artifacts. The JNI layer remains an integration boundary, not a functioning emulator. Runtime dependency loading, APK packaging, process lifecycle, SDL display/input, audio, and graphics backends remain subsequent implementation work. The QCOW2 creation screen is still a UI scaffold and does not create a disk.

## Native integration

See [native integration notes](native/README.md) for the pinned QEMU version,
Android ABI plan, and the next runtime integration steps.

## Build

Requirements: JDK 17, Android SDK platform 35, Android NDK 27.2.12479018,
CMake 3.22.1, and Gradle 8.10.2.

```sh
gradle :app:assembleDebug
```

## Licensing

Emu's original application source is MIT licensed; see [LICENSE](LICENSE). The installed APK exposes an **Open source notices** page in Settings with license texts and attributions for components currently packaged in the APK. QEMU build artifacts are not yet part of the APK; see [NOTICE](NOTICE) for the GPL-2.0 distribution boundary that applies when QEMU is packaged.

## Android background operation and phantom-process limits

Android can restrict or terminate background work to manage battery and memory. Allowing notifications and requesting a battery-optimization exemption can improve visibility and reduce some Doze restrictions, but neither makes an app immune to termination. A user force-stop, low-memory pressure, or manufacturer-specific task manager can still stop Emu. A real VM session will require a foreground service with an ongoing notification; that service is not implemented until the QEMU process lifecycle is integrated.

### Phantom-process limits (advanced ADB guide)

Some Android versions monitor child processes created by an application. This policy can terminate child processes when an application exceeds the phantom-process limit. The settings below are device-wide and are intended only for troubleshooting on a device you control. Behavior and availability vary by Android release and manufacturer; commands may be ignored, restricted, or reset after an update or reboot.

Connect the device with USB debugging enabled, authorize the computer, then check the current values:

```sh
adb shell settings get global settings_enable_monitor_phantom_procs
adb shell device_config get activity_manager max_phantom_processes
```

**Option 1 — disable phantom-process monitoring** (only if the Android build supports this setting):

```sh
adb shell settings put global settings_enable_monitor_phantom_procs 0
```

**Option 2 — increase the phantom-process limit:**

```sh
adb shell device_config set_sync_disabled_for_tests persistent
adb shell device_config put activity_manager max_phantom_processes 2147483647
```

The second option changes a system-wide ActivityManager configuration value. The large limit is a troubleshooting override, not a recommended everyday configuration. It can allow more child processes to remain alive and increase memory and battery consumption. Do not apply both options unless you understand the device-wide effects.

**Restore the platform defaults:**

```sh
adb shell settings delete global settings_enable_monitor_phantom_procs
adb shell device_config delete activity_manager max_phantom_processes
adb shell device_config set_sync_disabled_for_tests none
```

Deleting the overrides lets Android or the device manufacturer use its default values again. If a command reports that the setting is unavailable or permission is denied, do not try to bypass the device's security controls; consult the device manufacturer's documentation. These workarounds do not guarantee that QEMU or Emu will remain alive in the background.
