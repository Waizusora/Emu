#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="${QEMU_SOURCE_DIR:-$ROOT/.work/qemu}"
TAG="v9.2.0"
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
[[ ! -e "$SOURCE_DIR" ]] || { echo "source already exists: $SOURCE_DIR" >&2; exit 1; }
mkdir -p "$(dirname "$SOURCE_DIR")"
git clone --filter=blob:none --recurse-submodules --branch "$TAG" --depth 1 https://gitlab.com/qemu-project/qemu.git "$SOURCE_DIR"
actual="$(git -C "$SOURCE_DIR" describe --tags --exact-match HEAD)"
[[ "$actual" == "$TAG" ]] || { echo "expected $TAG, got $actual" >&2; exit 1; }
git -C "$SOURCE_DIR" submodule update --init --recursive
printf 'QEMU_TAG=%s\nQEMU_COMMIT=%s\n' "$TAG" "$(git -C "$SOURCE_DIR" rev-parse HEAD)" > "$ROOT/native/qemu-source.lock"
echo "Fetched upstream QEMU $TAG at $(git -C "$SOURCE_DIR" rev-parse HEAD)"
