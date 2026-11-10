#!/usr/bin/env bash
# Experimental cross-build entry point. Android is not in upstream QEMU's
# continuously tested host-OS matrix; this driver fails early on missing tools.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="${QEMU_SOURCE_DIR:-$ROOT/.work/qemu}"
ABI="${1:-arm64-v8a}"
API="${ANDROID_API:-28}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
BUILD_ROOT="${QEMU_BUILD_ROOT:-$ROOT/.work/qemu-build}"
case "$ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android ;;
  x86_64) TRIPLE=x86_64-linux-android ;;
  *) echo "supported ABI values: arm64-v8a, x86_64" >&2; exit 2 ;;
esac
[[ -x "$SOURCE_DIR/configure" ]] || { echo "run native/scripts/fetch-qemu.sh first" >&2; exit 2; }
[[ -n "$NDK" && -d "$NDK/toolchains/llvm/prebuilt/linux-x86_64" ]] || { echo "set ANDROID_NDK_HOME to Linux NDK r27+" >&2; exit 2; }
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$TOOLCHAIN/$TRIPLE$API-clang"
CXX="$TOOLCHAIN/$TRIPLE$API-clang++"
for tool in "$CC" "$CXX" "$TOOLCHAIN/llvm-ar"; do
  [[ -x "$tool" ]] || { echo "missing NDK tool: $tool" >&2; exit 2; }
done
BUILD_DIR="$BUILD_ROOT/$ABI"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
export CC CXX AR="$TOOLCHAIN/llvm-ar" RANLIB="$TOOLCHAIN/llvm-ranlib"
export CFLAGS="${CFLAGS:--O2 -fPIC}"
export CXXFLAGS="${CXXFLAGS:--O2 -fPIC}"
cat <<INFO
QEMU source: $SOURCE_DIR
Android ABI: $ABI ($TRIPLE), API $API
Build directory: $BUILD_DIR
This is an experimental configure attempt. Android/bionic support and the
cross-compiled GLib, pixman, libffi and zlib dependency sysroot are not yet
validated. A successful configure is not equivalent to a working runtime.
INFO
"$SOURCE_DIR/configure" \
  --prefix="$BUILD_DIR/install" \
  --target-list=aarch64-softmmu \
  --cc="$CC" --cxx="$CXX" --host-cc=cc \
  --enable-tcg --disable-kvm --disable-werror --disable-docs \
  --disable-gtk --disable-sdl --disable-vnc --disable-curses \
  --disable-opengl --disable-virglrenderer --disable-spice --disable-xen \
  --disable-cap-ng --disable-seccomp --disable-selinux \
  --disable-libnfs --disable-libiscsi --disable-rbd --disable-usb-redir
echo "QEMU configure completed. Runtime build and device validation remain pending."
