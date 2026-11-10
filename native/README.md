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

## Fetch the pinned source

Run the fetch script from the repository root:

```sh
bash native/scripts/fetch-qemu.sh
```

The script checks out the upstream `v9.2.0` tag and its recursive submodules
under `.work/qemu`. It records the resolved source revision in
`native/qemu-source.lock`. Keep the generated lock file with source changes
when updating the pinned engine.

## Generate an Android Meson cross file

Meson-based Android dependencies need a machine file that points to the NDK
compiler and the ABI-specific dependency prefix. Generate it with:

```sh
export ANDROID_NDK_HOME="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_API=28
export QEMU_ANDROID_SYSROOT="$HOME/android-sysroots/arm64-v8a"

bash native/scripts/create-android-meson-cross-file.sh arm64-v8a
```

The generated file is written to
`.work/meson/android-arm64-v8a.ini` by default. Pass a second argument to
select another output path. For a Meson dependency build, pass that file with
`--cross-file`. Generate a separate file and use a separate dependency prefix
for `x86_64`; never reuse ARM64 libraries in an x86_64 build.

The generator uses the NDK compiler's built-in Android platform sysroot and
restricts Meson's pkg-config lookup to the selected dependency prefix. This
keeps target library metadata separate from host Linux packages. The generated
file is a build configuration helper, not proof that the dependency stack has
already been built or validated.

## Android cross-build prerequisites

The QEMU cross-build is deliberately fail-fast. It does not use host Linux
libraries as substitutes for Android libraries. Prepare an ABI-specific
dependency sysroot containing Android builds of at least:

- GLib 2.x (`glib-2.0` pkg-config module)
- Pixman (`pixman-1` pkg-config module)
- Any additional dependencies reported by QEMU's configure checks.

The sysroot must match the selected Android ABI and API level. Its pkg-config
metadata must describe target libraries, not host libraries. The build host
also needs JDK-independent native tools: Bash, Git, a C/C++ host compiler,
`pkg-config`, and Ninja. Install Android NDK r27 or newer.

Example for an already-prepared ARM64 sysroot (replace paths with real local
paths; the repository does not ship prebuilt third-party libraries):

```sh
export ANDROID_NDK_HOME="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_API=28
export QEMU_ANDROID_SYSROOT="$HOME/android-sysroots/arm64-v8a"
export QEMU_PKG_CONFIG_LIBDIR="$QEMU_ANDROID_SYSROOT/usr/lib/pkgconfig:$QEMU_ANDROID_SYSROOT/usr/share/pkgconfig"

bash native/scripts/build-qemu-android.sh arm64-v8a
```

For x86_64, prepare a separate x86_64 sysroot and set the two sysroot
variables to its paths before running:

```sh
bash native/scripts/build-qemu-android.sh x86_64
```

Build outputs are isolated by ABI under `.work/qemu-build/<abi>/`. The script
builds `qemu-system-aarch64` and `qemu-img` only after QEMU configuration
succeeds. It checks that GLib and Pixman are available through the supplied
target pkg-config path, and stops with an actionable error if prerequisites
are missing.

## Android CI checks

The GitHub Actions workflow installs Android platform 35, build-tools 35.0.0,
NDK 27.2.12479018, and CMake 3.22.1 before compiling the APK. It parses each
shell script independently, builds the debug APK, and verifies that the JNI
bridge is packaged for both supported ABIs:

```sh
bash native/scripts/verify-android-apk.sh app/build/outputs/apk/debug/app-debug.apk
```

The verifier checks only that `libemu-qemu.so` is present in each APK ABI
folder. It does not imply that the QEMU engine itself is included or runnable.

**Important:** this is an experimental cross-build path, not a verified
Android port. A successful configure or link is not proof that the binaries
load on API 28+, have all runtime dependencies packaged, or boot a guest.
Those checks still require ELF dependency inspection and tests on physical
Android devices. Android is not part of QEMU's ordinary upstream host
validation matrix; AOSP maintains a separate Android QEMU build workflow.
See the upstream [QEMU build-system documentation](https://qemu.readthedocs.io/en/v9.2.0/devel/build-system.html)
and [AOSP QEMU development notes](https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/android/docs/DEVELOPMENT.md).

## Planned app integration

1. Establish reproducible dependency builds for both Android host ABIs.
2. Resolve QEMU 9.2.0 Android/Bionic portability issues exposed by configure,
   compile, link, and device tests. Keep any compatibility patches isolated
   and documented; do not silently modify upstream source.
3. Verify the emulator and `qemu-img` ELF dependencies and package all required
   Android-compatible shared libraries.
4. Expose a supported QEMU entry point through JNI. Keep QEMU command-line
   parsing, callbacks, and process lifecycle isolated from the Compose UI.
5. Connect QCOW2 create/info/resize/convert operations to the Storage UI only
   after the Android `qemu-img` binary is available and tested.
6. Add SDL Android-surface display/input and audio integration after basic
   headless boot and shutdown tests pass.

## Licensing

QEMU is GPL-2.0 licensed. Distribution of a linked or modified QEMU runtime
must satisfy the applicable GPL source, notice, and corresponding-source
requirements. Keep upstream QEMU and dependency license texts with the
distributed application. The app's MIT license does not relicense QEMU.
