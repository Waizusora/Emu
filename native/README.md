# Native QEMU integration

## Pinned engine target

- QEMU release: **9.2.0**
- Guest machine architecture: AArch64 (`qemu-system-aarch64`)
- Android host ABIs: `arm64-v8a`, `x86_64`
- Execution accelerator: TCG; Android KVM is not assumed.
- Android API floor: 28.

## CPU acceleration: TCG and optional Android KVM

TCG is always compiled and remains the portable default for both Android host
ABIs. The guest remains AArch64 in both builds:

| Android host ABI | AArch64 guest acceleration |
| --- | --- |
| `arm64-v8a` | TCG by default; optional KVM when the device kernel and Android security policy expose usable KVM |
| `x86_64` | TCG only; an x86_64 host cannot use ARM KVM to accelerate an AArch64 guest |

KVM is a **build-time optional feature**, not a promise that the running device
can use it. To include the KVM accelerator code in an ARM64 build, set:

```sh
export QEMU_ENABLE_KVM=1
bash native/scripts/build-qemu-android.sh arm64-v8a
```

The default is `QEMU_ENABLE_KVM=0`, which explicitly disables KVM and builds
TCG. Setting `QEMU_ENABLE_KVM=1` for `x86_64` is rejected because the host
and AArch64 guest architectures do not match. The CI default remains TCG-only;
KVM-enabled builds should be tested as a separate ARM64 build variant.

### Device-side KVM prerequisites

There is no single Android release or GKI version that guarantees application
access to KVM. KVM support exists in Android common ARM64 GKI configurations
including Android 13's 5.15 branch, but a device still needs a compatible
kernel configuration, hardware virtualization support, an operational KVM
device node, and permission for the app process to open it. Vendor kernels,
boot configuration, SELinux policy, protected-KVM mode, and device policy can
change availability. Kernel version alone is not a sufficient capability
test.

On a device you control, inspect the kernel and KVM node with ADB:

```sh
adb shell uname -a
adb shell ls -l /dev/kvm
adb shell cat /proc/misc
```

If the device exposes its kernel configuration, check for the relevant
configuration options:

```sh
adb shell 'zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_(VIRTUALIZATION|KVM)="'
```

Expected ARM64 kernel options include `CONFIG_VIRTUALIZATION=y` and
`CONFIG_KVM=y`. Some devices do not expose `/proc/config.gz`; absence of
that file does not prove KVM is disabled. The decisive runtime check is
whether the Emu process can open `/dev/kvm` and successfully initialize the
KVM API. A visible node without app permissions is not sufficient.

The application must probe KVM at runtime and select `-accel kvm` only after
successful initialization; otherwise it must use `-accel tcg`. Never infer
KVM availability solely from Android version, kernel version, SoC model, or
the presence of a GKI label. Do not instruct users to bypass SELinux or device
security policy to obtain KVM access.

AOSP's published GKI kernel matrix documents supported kernel branches, and
the ARM64 GKI defconfig shows the virtualization/KVM config selections. These
are references for kernel capability, not guarantees of app-level access:
- [Android common kernel and GKI compatibility](https://source.android.com/docs/core/architecture/kernel/android-common)
- [ARM64 KVM kernel configuration](https://android.googlesource.com/kernel/common/+/refs/heads/android-mainline/arch/arm64/kvm/Kconfig)
- [AOSP ARM64 GKI defconfig](https://android.googlesource.com/kernel/common/+/refs/heads/android13-5.15/arch/arm64/configs/gki_defconfig)

## Current implementation

The Android app builds `libemu-qemu.so` with the Android NDK and CMake for
both configured ABIs. `QemuRuntime.kt` exposes a small JNI capability/status
API to Kotlin.

This is intentionally only the native boundary. The current bridge returns
`isAvailable = false`; it does not contain QEMU source, execute guest code,
or provide `qemu-img`. Do not change that result until a real QEMU engine is
built, packaged, and exercised on-device.

## Android compatibility patches

Repository-maintained QEMU portability patches are stored in `native/patches/`
and applied by `native/scripts/fetch-qemu.sh` immediately after the pinned
upstream source and submodules are fetched. Patch files are checked with
`git apply --check` before application, so an upstream source mismatch fails
rather than silently applying a partial change.

The first patch addresses an Android Bionic header collision in QEMU's 9P
marshal structure: Bionic defines `st_atime_nsec`, `st_mtime_nsec`, and
`st_ctime_nsec` as macros, which otherwise rewrite the identically named 9P
protocol fields. The second patch probes the target compiler for the POSIX `shm_open` API
before adding QEMU's optional shared-memory host backend. This is more robust
than checking the reported host OS because the current cross-configuration can
report the build OS rather than Android. Bionic does not provide the required
API, so `memory-backend-shm` is omitted on this target. File-backed host memory
and ordinary virtual disk images remain available. Keep these changes isolated from
upstream source and add a new versioned patch when another Android-specific
portability issue is identified.

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

## Inspect the QEMU Android ELF outputs

After each ABI cross-build, CI runs
`native/scripts/inspect-qemu-android-elf.sh` against both
`qemu-system-aarch64` and `qemu-img`. It verifies the ELF machine,
requires Android's 64-bit system linker (`/system/bin/linker64`), requires build-host `RPATH`/`RUNPATH` entries to be removed with
`patchelf` before artifact upload, and prints every `DT_NEEDED`
shared-library dependency into the CI log.

Run the inspection locally after a successful QEMU build:

```sh
export ANDROID_NDK_HOME="$HOME/Android/Sdk/ndk/27.2.12479018"
bash native/scripts/inspect-qemu-android-elf.sh arm64-v8a
```

This check validates ELF metadata only. It does not prove that every shared
library is available to an app process on a device, nor that QEMU can start.
The next integration gate is to resolve the reported dependencies, package
the executables and any permitted runtime libraries, then perform device-side
version/help and guest-boot smoke tests before enabling the JNI runtime.

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

## Preserve and verify QEMU relink materials

CI publishes the ABI-specific QEMU build directory separately from the
matching dependency sysroot and corresponding-source archive. The build
directory retains QEMU object files, `build.ninja`, compile commands, and
Meson configuration metadata. The sysroot retains the static dependency
archives and shared zlib library referenced by the generated link metadata.

Before upload, CI runs:

```sh
bash native/scripts/verify-qemu-relink-materials.sh arm64-v8a
bash native/scripts/verify-qemu-relink-materials.sh x86_64
```

This verifies that the expected inputs are present and referenced by the
link metadata. It does not prove that a relink has been completed, that the
result is byte-for-byte reproducible, or that every applicable license
obligation has been satisfied. Keep the build, sysroot, and corresponding
source artifacts from the same CI run together.

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


## QEMU cross-link toolchain handling

The QEMU build driver explicitly selects the NDK LLVM binutils rather than
assuming GNU tools named after the Android target triple exist. It also
creates a local pkg-config wrapper that requests static dependency metadata,
so GLib and Pixman private link requirements are included while QEMU itself
remains a normal Android executable. The target lookup is restricted to the
ABI-specific sysroot and requires `glib-2.0`, `pixman-1`, and `zlib`.

The wrapper is generated under the ignored `.work/toolchain` directory and
is not committed as a generated build artifact.
