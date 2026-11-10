#!/usr/bin/env bash
# Fetch the pinned QEMU release and apply the repository's Android portability patches.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="${QEMU_SOURCE_DIR:-$ROOT/.work/qemu}"
TAG="v9.2.0"
PATCH_DIR="$ROOT/native/patches"
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v patch >/dev/null 2>&1 || { echo "patch is required" >&2; exit 1; }
[[ ! -e "$SOURCE_DIR" ]] || { echo "source already exists: $SOURCE_DIR" >&2; exit 1; }
mkdir -p "$(dirname "$SOURCE_DIR")"
git clone --filter=blob:none --recurse-submodules --branch "$TAG" --depth 1 https://gitlab.com/qemu-project/qemu.git "$SOURCE_DIR"
actual="$(git -C "$SOURCE_DIR" describe --tags --exact-match HEAD)"
[[ "$actual" == "$TAG" ]] || { echo "expected $TAG, got $actual" >&2; exit 1; }
git -C "$SOURCE_DIR" submodule update --init --recursive

# Apply version-controlled Android compatibility patches in lexical order.
if [[ -d "$PATCH_DIR" ]]; then
  while IFS= read -r -d '' patch_file; do
    echo "Applying $(basename "$patch_file")"
    git -C "$SOURCE_DIR" apply --check "$patch_file"
    git -C "$SOURCE_DIR" apply "$patch_file"
  done < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
fi
printf 'QEMU_TAG=%s\nQEMU_COMMIT=%s\n' "$TAG" "$(git -C "$SOURCE_DIR" rev-parse HEAD)" > "$ROOT/native/qemu-source.lock"
echo "Fetched and patched upstream QEMU $TAG at $(git -C "$SOURCE_DIR" rev-parse HEAD)"
