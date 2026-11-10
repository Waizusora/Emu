# Native QEMU integration

## Pinned engine target

- QEMU release: **9.2.0**
- Guest machine architecture: AArch64 (`qemu-system-aarch64`)
- Android host ABIs: `arm64-v8a`, `x86_64`
- Execution accelerator: TCG; Android KVM is not assumed.
- Android API floor: 28.

## Current implementation

The Android app builds `libemu-qemu.so` with the Android NDK and CMake for
both configured ABIs. `QemuRuntime.kt` exposes a small JNI capability/status
API to Kotlin.

This is intentionally only the native boundary. The current bridge returns
`isAvailable = false`; it does not contain QEMU source, execute guest code,
or provide `qemu-img`. Do not change that result until a real QEMU engine is
built, packaged, and exercised on-device.

## Planned engine integration

1. Import the unmodified QEMU 9.2.0 source and record its exact upstream
   revision and source archive digest.
2. Establish reproducible Android cross-builds for each host ABI, including
   QEMU's Meson configuration and required third-party dependencies.
3. Build and package the AArch64 system emulator with TCG and only the device
   backends required by Emu. Validate that all dynamic dependencies are
   packaged and loadable on API 28+.
4. Expose a supported QEMU entry point through JNI. Keep QEMU's command-line
   parsing and lifecycle isolated from the Compose UI.
5. Build `qemu-img` for Android and connect QCOW2 create/info/resize/convert
   operations to the Storage UI.
6. Add SDL Android-surface display/input and audio integration after basic
   headless boot and shutdown tests pass.

## Licensing

QEMU is GPL-2.0 licensed. Distribution of a linked or modified QEMU runtime
must satisfy the applicable GPL source, notice, and corresponding-source
requirements. Keep upstream QEMU and dependency license texts with the
distributed application. The app's MIT license does not relicense QEMU.
