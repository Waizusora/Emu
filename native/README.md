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

## Build the first Android dependency (zlib)

The dependency pipeline starts with a pinned static zlib build. The script
uses the Android NDK CMake toolchain and installs headers and libraries into
one ABI-specific prefix:

```sh
export ANDROID_NDK_HOME="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_API=28
export QEMU_ANDROID_SYSROOT="$HOME/android-sysroots/arm64-v8a"

bash native/scripts/build-zlib-android.sh arm64-v8a
```

Use a separate prefix for `x86_64`. The default prefix is
`.work/sysroots/<abi>`; set `QEMU_ANDROID_SYSROOT` to override it. Source
and build directories are isolated under `.work/deps`. The script checks
out the exact upstream zlib tag `v1.3.1` and does not build or claim to
provide GLib or Pixman. The QEMU build remains blocked until those required
dependencies and any configure-detected dependencies are built for the same
ABI.

This script is syntax-checked by CI, but dependency compilation is not yet a
CI job and has not been represented as a validated Android build.

## Build the Android dependency foundation

The current dependency scripts build three pinned components for one ABI.
Install host tools `git`, `curl`, `tar`, `make`, CMake, Ninja, Meson,
Python 3, and pkg-config, then run:

```sh
export ANDROID_NDK_HOME="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_API=28
bash native/scripts/build-android-deps.sh arm64-v8a
```

The orchestrator builds zlib 1.3.1, libffi 3.4.6, and PCRE2 10.44, then
generates the Meson cross file. Use `x86_64` as a separate invocation and
keep each ABI's sysroot separate. This is not yet a complete QEMU dependency
sysroot: GLib and Pixman still need Android builds before QEMU can configure.
These native dependency builds are not currently part of the hosted CI job.

## Build the complete QEMU dependency sysroot

The dependency orchestrator now builds the pinned native stack in order:
zlib 1.3.1, libffi 3.4.6, PCRE2 10.44, GLib 2.82.4, and Pixman 0.44.2.
The first three components use CMake or Autoconf; GLib and Pixman use the
generated Meson cross file.

Host requirements: Android NDK r27+, CMake, Ninja, Meson 1.3+, Python 3,
pkg-config, Git, curl, tar, and make. On a Linux build host, run:

```sh
export ANDROID_NDK_HOME="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_API=28
bash native/scripts/build-android-deps.sh arm64-v8a
```

Run the same command with `x86_64` to build a separate ABI sysroot. The
default install prefix is `.work/sysroots/<abi>/usr`; override it with
`QEMU_ANDROID_SYSROOT`. Sources and build trees remain under ignored
`.work/deps` directories. The orchestrator checks that `glib-2.0` and
`pixman-1` are visible through target pkg-config metadata before returning
success.

A completed script run is a dependency-build result, not proof that QEMU 9.2
itself compiles or runs on Android. The QEMU cross-build still needs configure
and link validation, runtime ELF inspection, packaging, and physical-device
tests. The dependency pipeline is not run in hosted CI yet; CI currently
checks shell syntax and the Android app/JNI packaging only.


## Verify the Android dependency sysroot

After the dependency orchestrator completes, it runs
`native/scripts/verify-android-sysroot.sh`. The verifier checks that the
selected ABI prefix contains the expected static archives and that zlib,
libffi, PCRE2, GLib, and Pixman pkg-config modules resolve inside that prefix.
It also checks static link metadata for GLib and Pixman. Run it independently
with:

```sh
bash native/scripts/verify-android-sysroot.sh arm64-v8a
```

This is a structural sysroot check only. It does not establish that the
libraries load on Android or that QEMU compiles or boots successfully.
