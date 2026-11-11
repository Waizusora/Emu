#!/usr/bin/env bash
# Assemble the exact upstream sources and local patches used by the Android QEMU build.
# This is a corresponding-source artifact, not a binary or a legal-compliance opinion.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QEMU_SOURCE_DIR="${QEMU_SOURCE_DIR:-$ROOT/.work/qemu}"
DEPS_SOURCE_ROOT="${NATIVE_DEPS_SOURCE_ROOT:-$ROOT/.work/deps/src}"
OUTPUT_DIR="${QEMU_SOURCE_BUNDLE_DIR:-$ROOT/.work/source-bundle}"
STAGING_DIR="$OUTPUT_DIR/staging"
ARCHIVE="$OUTPUT_DIR/emu-qemu-9.2.0-corresponding-source.tar.xz"

# Require every source tree consumed by the pinned Android dependency build.
required_paths=(
  "$QEMU_SOURCE_DIR/COPYING"
  "$DEPS_SOURCE_ROOT/zlib-1.3.1"
  "$DEPS_SOURCE_ROOT/libffi-3.4.6/LICENSE"
  "$DEPS_SOURCE_ROOT/pcre2-10.44/LICENCE"
  "$DEPS_SOURCE_ROOT/glib-2.82.4/COPYING"
  "$DEPS_SOURCE_ROOT/pixman-0.44.2"
  "$ROOT/native/qemu-source.lock"
  "$ROOT/native/patches"
  "$ROOT/native/scripts"
)
for path in "${required_paths[@]}"; do
  [[ -e "$path" ]] || {
    echo "ERROR: corresponding source input is missing: $path" >&2
    exit 1
  }
done

# Pixman release archives may name their license COPYING or COPYING.LIB.
if ! find "$DEPS_SOURCE_ROOT/pixman-0.44.2" -maxdepth 2 -type f \
    \( -iname 'copying' -o -iname 'copying.lib' -o -iname 'license*' \) \
    -print -quit | grep -q .; then
  echo "ERROR: Pixman source tree contains no recognizable license file" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Preserve source files and submodule contents, while excluding Git metadata.
tar --exclude-vcs -C "$ROOT" -cf - \
  LICENSE NOTICE native/README.md native/scripts native/patches \
  native/qemu-source.lock .work/qemu \
  .work/deps/src/zlib-1.3.1 \
  .work/deps/src/libffi-3.4.6 \
  .work/deps/src/pcre2-10.44 \
  .work/deps/src/glib-2.82.4 \
  .work/deps/src/pixman-0.44.2 \
  | tar -C "$STAGING_DIR" -xf -

{
  echo "Emu Android QEMU corresponding-source bundle"
  echo "QEMU: 9.2.0 (upstream v9.2.0; see native/qemu-source.lock)"
  echo "Android API floor: 28"
  echo "Host ABIs built by CI: arm64-v8a, x86_64"
  echo "QEMU accelerator configuration: TCG default; KVM disabled in CI"
  echo "Static dependency source versions:"
  echo "  zlib 1.3.1"
  echo "  libffi 3.4.6"
  echo "  PCRE2 10.44"
  echo "  GLib 2.82.4"
  echo "  Pixman 0.44.2"
  echo
  echo "This bundle includes upstream source trees, QEMU submodule source,"
  echo "repository Android patches, and the native build scripts."
  echo "Build instructions and license files are included in the source trees."
  echo "The archive is provided as a source artifact associated with the CI build."
  echo "Review the applicable licenses and distribution obligations before"
  echo "redistributing binaries; this bundle is not legal advice."
  echo
  echo "SHA-256 of repository-maintained QEMU patches:"
  if compgen -G "$ROOT/native/patches/*.patch" >/dev/null; then
    (cd "$ROOT" && sha256sum native/patches/*.patch)
  else
    echo "(no QEMU patches)"
  fi
} > "$STAGING_DIR/SOURCE-MANIFEST.txt"

mkdir -p "$OUTPUT_DIR"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -C "$STAGING_DIR" -cJf "$ARCHIVE" .
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Created corresponding-source archive: $ARCHIVE"
echo "Archive checksum: $ARCHIVE.sha256"
