# Emu

Emu is an Android GUI for managing full-system Linux virtual machines using QEMU.
The project targets AArch64 guests and Android devices with `arm64-v8a` or
`x86_64` host ABIs. It does not bundle a Linux distribution; users provide
their own installation ISO and virtual disk images.

## Current status

The initial Android application scaffold includes:

- Kotlin and Jetpack Compose with Material 3.
- A compact Home, Storage, and Settings navigation layout.
- System document picker flows for selecting ISO and QCOW2 files.
- Persistable read access for user-selected document URIs where supported.
- A landscape-orientation preference.
- Android CI workflow for building the debug APK.
- App module ABI filters for `arm64-v8a` and `x86_64`.

The QEMU runtime, SDL display/input integration, audio, graphics backends, VM
lifecycle, and native `qemu-img` operations are not integrated yet. The
QCOW2 creation screen is currently a UI scaffold and does not create a disk.

## Build

Requirements: JDK 17, Android SDK platform 35, and Gradle 8.10.2.

```sh
gradle :app:assembleDebug
```

## Licensing

Emu's original application source is MIT licensed; see [LICENSE](LICENSE).
Third-party components retain their own licenses. See [NOTICE](NOTICE) for
the QEMU distribution and GPL compliance boundary.
