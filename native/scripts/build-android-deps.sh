#!/usr/bin/env bash
# Build the currently supported third-party Android dependency stages.
# GLib and Pixman are separate future stages; this script reports that limit.

set -euo pipefail

# Resolve repository root and target ABI once for the dependency chain.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ABI="${1:-arm64-v8a}"

# Share one isolated sysroot among libraries built for the selected ABI.
export QEMU_ANDROID_SYSROOT="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
mkdir -p "$QEMU_ANDROID_SYSROOT"

# Build the foundational compression and GLib prerequisite libraries.
bash "$ROOT/native/scripts/build-zlib-android.sh" "$ABI"
bash "$ROOT/native/scripts/build-libffi-android.sh" "$ABI"
bash "$ROOT/native/scripts/build-pcre2-android.sh" "$ABI"

# Generate the Meson cross file after dependency metadata is installed.
bash "$ROOT/native/scripts/create-android-meson-cross-file.sh" "$ABI"

echo "Completed current native dependency stages for $ABI."
echo "GLib and Pixman are not built yet; QEMU remains blocked until both are installed."
