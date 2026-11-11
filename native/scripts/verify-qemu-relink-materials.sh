#!/usr/bin/env bash
# Verify that a QEMU build artifact retains the inputs needed for relinking.
# This is a structural check, not a legal-compliance determination.

set -euo pipefail

ABI="${1:?Usage: verify-qemu-relink-materials.sh <arm64-v8a|x86_64>}"
case "$ABI" in
  arm64-v8a|x86_64) ;;
  *)
    echo "ERROR: unsupported Android ABI: $ABI" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="${QEMU_BUILD_ROOT:-$ROOT/.work/qemu-build}"
SYSROOT_ROOT="${QEMU_ANDROID_SYSROOT:-$ROOT/.work/sysroots/$ABI}"
BUILD_DIR="$BUILD_ROOT/$ABI"
SYSROOT_LIB="$SYSROOT_ROOT/usr/lib"

for path in \
  "$BUILD_DIR/build.ninja" \
  "$BUILD_DIR/compile_commands.json" \
  "$BUILD_DIR/meson-private/coredata.dat" \
  "$BUILD_DIR/qemu-system-aarch64" \
  "$BUILD_DIR/qemu-img" \
  "$BUILD_DIR/qemu-system-aarch64.p/system_main.c.o" \
  "$BUILD_DIR/qemu-img.p/qemu-img.c.o"; do
  [[ -s "$path" ]] || {
    echo "ERROR: required QEMU relink input is missing or empty: $path" >&2
    exit 1
  }
done

for binary in "$BUILD_DIR/qemu-system-aarch64" "$BUILD_DIR/qemu-img"; do
  [[ -x "$binary" ]] || {
    echo "ERROR: QEMU output is not executable: $binary" >&2
    exit 1
  }
done

object_count="$(find "$BUILD_DIR" -type f -name '*.o' -size +0c | wc -l | tr -d ' ')"
if (( object_count < 1000 )); then
  echo "ERROR: expected at least 1000 retained QEMU object files; found $object_count" >&2
  exit 1
fi

# Keep the complete ABI sysroot. These are available relink inputs, not a claim
# that every archive is a direct argument of each final executable. Meson may
# express dependencies transitively or through generated linker response data.
for library in \
  libffi.a \
  libgio-2.0.a \
  libglib-2.0.a \
  libgmodule-2.0.a \
  libgobject-2.0.a \
  libintl.a \
  libpcre2-8.a \
  libpixman-1.a \
  libz.so; do
  [[ -s "$SYSROOT_LIB/$library" ]] || {
    echo "ERROR: relink dependency is missing from ABI sysroot: $SYSROOT_LIB/$library" >&2
    exit 1
  }
done

# Ninja's command tool expands command variables but intentionally leaves
# response-file contents opaque. Meson uses c_LINKER_RSP for large targets, so
# the final "-o <target>" is in rspfile_content rather than the printed command.
# Validate the exact Ninja edge, its linker rule, the response-file output
# contract, and the last command in the target's dependency graph.
python3 - "$BUILD_DIR" <<'PY'
import pathlib
import re
import subprocess
import sys

build_dir = pathlib.Path(sys.argv[1])
build_ninja = (build_dir / "build.ninja").read_text(encoding="utf-8")
lines = build_ninja.splitlines()

for target in ("qemu-system-aarch64", "qemu-img"):
    edge_prefix = f"build {target}: "
    edge_index = next(
        (index for index, line in enumerate(lines) if line.startswith(edge_prefix)),
        None,
    )
    if edge_index is None:
        raise SystemExit(f"ERROR: build.ninja has no final build edge for {target}")

    edge = lines[edge_index]
    rule_name = edge[len(edge_prefix):].split()[0]
    rule_header = f"rule {rule_name}"
    rule_index = next(
        (index for index, line in enumerate(lines) if line == rule_header),
        None,
    )
    if rule_index is None:
        raise SystemExit(f"ERROR: Ninja rule {rule_name} for {target} is missing")

    rule_lines = []
    for line in lines[rule_index + 1:]:
        if not line or not line[0].isspace():
            break
        rule_lines.append(line.strip())

    rule = {}
    for line in rule_lines:
        key, separator, value = line.partition(" = ")
        if separator:
            rule[key] = value

    command_template = rule.get("command", "")
    if not command_template or not re.search(r"(?:clang|ld\.lld)", command_template):
        raise SystemExit(f"ERROR: {target} does not use a recognizable Android linker rule")

    rsp_content = rule.get("rspfile_content")
    if rsp_content is not None:
        if "@$out.rsp" not in command_template:
            raise SystemExit(f"ERROR: {target} response-file rule does not pass its output response file")
        if not re.search(r"(?:^|\s)-o\s+\$out(?:\s|$)", rsp_content):
            raise SystemExit(f"ERROR: {target} response-file template does not link to the declared output")
        if "$in" not in rsp_content or "$LINK_ARGS" not in rsp_content:
            raise SystemExit(f"ERROR: {target} response-file template omits objects or linker arguments")
    else:
        if not re.search(r"(?:^|\s)-o\s+\$out(?:\s|$)", command_template):
            raise SystemExit(f"ERROR: {target} linker command does not emit the declared output")
        if "$in" not in command_template or "$LINK_ARGS" not in command_template:
            raise SystemExit(f"ERROR: {target} linker command omits objects or linker arguments")

    if not any(line.startswith(" LINK_ARGS = ") for line in lines[edge_index + 1:edge_index + 5]):
        raise SystemExit(f"ERROR: {target} final link edge has no retained LINK_ARGS metadata")

    query = subprocess.run(
        ["ninja", "-C", str(build_dir), "-t", "query", target],
        check=True, capture_output=True, text=True,
    ).stdout
    if not query.startswith(f"{target}:") or f"input: {rule_name}" not in query:
        raise SystemExit(f"ERROR: Ninja query does not resolve {target} to its final linker edge")

    commands = subprocess.run(
        ["ninja", "-C", str(build_dir), "-t", "commands", target],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    final_command = next((line for line in reversed(commands) if line.strip()), "")
    if not final_command or "clang" not in final_command and "ld.lld" not in final_command:
        raise SystemExit(f"ERROR: Ninja command graph has no final linker command for {target}")

    if rsp_content is not None:
        if f"@{target}.rsp" not in final_command:
            raise SystemExit(f"ERROR: final linker command does not consume {target}.rsp")
    elif not re.search(rf"(?:^|\s)-o\s+{re.escape(target)}(?:\s|$)", final_command):
        raise SystemExit(f"ERROR: final linker command does not emit {target}")

    print(f"Verified Ninja final link edge: {target} ({rule_name})")
PY

echo "Verified QEMU relink materials for $ABI"
echo "  object files: $object_count"
echo "  build metadata: build.ninja, compile_commands.json, Meson coredata"
echo "  final link commands: qemu-system-aarch64, qemu-img"
echo "  complete ABI dependency sysroot: $SYSROOT_LIB"
