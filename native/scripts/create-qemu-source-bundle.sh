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
ARCHIVE_NAME="$(basename "$ARCHIVE")"
CHECKSUM_NAME="$ARCHIVE_NAME.sha256"

# Require every source tree consumed by the pinned Android dependency build.
required_paths=(
  "$QEMU_SOURCE_DIR/COPYING"
  "$DEPS_SOURCE_ROOT/zlib-1.3.1/LICENSE"
  "$DEPS_SOURCE_ROOT/libffi-3.4.6/LICENSE"
  "$DEPS_SOURCE_ROOT/pcre2-10.44/LICENCE"
  "$DEPS_SOURCE_ROOT/glib-2.82.4/LICENSES/LGPL-2.1-or-later.txt"
  "$DEPS_SOURCE_ROOT/glib-2.82.4/subprojects/gvdb/COPYING"
  "$DEPS_SOURCE_ROOT/glib-2.82.4/subprojects/proxy-libintl/COPYING"
  "$DEPS_SOURCE_ROOT/pixman-0.44.2/COPYING"
  "$ROOT/native/qemu-source.lock"
  "$ROOT/native/patches"
  "$ROOT/native/scripts"
)
for path in "${required_paths[@]}"; do
  [[ -e "$path" ]] || {
    echo "ERROR: corresponding source input is missing: $path" >&2
    exit 1
  }
  if [[ -f "$path" && ! -s "$path" ]]; then
    echo "ERROR: required license/source marker is empty: $path" >&2
    exit 1
  fi
done

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

# Add a concise license locator alongside the complete upstream license texts.
cat > "$STAGING_DIR/THIRD-PARTY-NOTICES.txt" <<'NOTICES'
Emu Android QEMU native build — third-party license locator

The source trees below are included in this archive. The listed files are
the authoritative license texts shipped with the corresponding source.

QEMU 9.2.0
  License: GNU General Public License, version 2
  Text: .work/qemu/COPYING

zlib 1.3.1
  License: zlib license
  Text: .work/deps/src/zlib-1.3.1/LICENSE

libffi 3.4.6
  License: MIT-style license (see upstream text for full terms)
  Text: .work/deps/src/libffi-3.4.6/LICENSE

PCRE2 10.44
  License: BSD 3-Clause
  Text: .work/deps/src/pcre2-10.44/LICENCE

GLib 2.82.4
  License: GNU Lesser General Public License, version 2.1 or later
  Text: .work/deps/src/glib-2.82.4/LICENSES/LGPL-2.1-or-later.txt
  Included GLib subprojects:
    GVDB: .work/deps/src/glib-2.82.4/subprojects/gvdb/COPYING
    proxy-libintl: .work/deps/src/glib-2.82.4/subprojects/proxy-libintl/COPYING

Pixman 0.44.2
  License: MIT
  Text: .work/deps/src/pixman-0.44.2/COPYING

This locator is not a complete binary dependency analysis or legal opinion.
Consult each included source tree for additional copyright notices, licenses,
and terms applicable to files or subcomponents actually incorporated into a
specific build. Build-time-only components are not necessarily linked into
the QEMU executables.
NOTICES

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
  echo "Build instructions, THIRD-PARTY-NOTICES.txt, and complete license texts"
  echo "are included in the source trees."
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

# Write a relocatable checksum sidecar and verify it before publishing the bundle.
(
  cd "$OUTPUT_DIR"
  sha256sum "$ARCHIVE_NAME" > "$CHECKSUM_NAME"
  sha256sum --check "$CHECKSUM_NAME"
)
echo "Created corresponding-source archive: $ARCHIVE"
echo "Archive checksum: $OUTPUT_DIR/$CHECKSUM_NAME"
