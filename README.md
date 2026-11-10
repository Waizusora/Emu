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

**QEMU itself is not yet built or packaged.** The JNI layer is an integration
boundary, not a functioning emulator. QEMU 9.2.0 source/build integration,
the `qemu-system-aarch64` runtime, `qemu-img`, VM lifecycle, SDL display/input,
audio, and graphics backends remain subsequent implementation work. The
QCOW2 creation screen is still a UI scaffold and does not create a disk.

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

Emu's original application source is MIT licensed; see [LICENSE](LICENSE).
Third-party components retain their own licenses. See [NOTICE](NOTICE) for
the QEMU distribution and GPL compliance boundary.
