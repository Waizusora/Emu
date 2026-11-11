#!/usr/bin/env bash
# Verify APK JNI bridges, QEMU executables, ELF metadata, checksums, and notices.
set -euo pipefail

APK="\${1:-app/build/outputs/apk/debug/app-debug.apk}"

if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK not found: $APK" >&2
  exit 2
fi
command -v unzip >/dev/null 2>&1 || {
  echo "ERROR: unzip is required to inspect the APK" >&2
  exit 2
}

CONTENTS="$(unzip -Z1 "$APK")"
for ABI in arm64-v8a x86_64; do
  LIBRARY="lib/$ABI/libemu-qemu.so"
  if ! grep -Fqx "$LIBRARY" <<< "$CONTENTS"; then
    echo "ERROR: APK is missing $LIBRARY" >&2
    exit 1
  fi
  echo "OK: $LIBRARY"
done

for LICENSE_ASSET in \
  assets/licenses/mit.txt \
  assets/licenses/apache-2.0.txt \
  assets/licenses/gpl-2.0.txt \
  assets/licenses/NOTICE.txt; do
  if ! grep -Fqx "$LICENSE_ASSET" <<< "$CONTENTS"; then
    echo "ERROR: APK is missing $LICENSE_ASSET" >&2
    exit 1
  fi
  echo "OK: $LICENSE_ASSET"
done

python3 - "$APK" <<'PY'
import hashlib
import re
import struct
import sys
import zipfile

apk = sys.argv[1]
expected_machines = {"arm64-v8a": 183, "x86_64": 62}
executables = {"qemu-system-aarch64", "qemu-img"}

with zipfile.ZipFile(apk) as archive:
    names = set(archive.namelist())
    for abi, expected_machine in expected_machines.items():
        manifest_path = "assets/qemu/" + abi + "/SHA256SUMS"
        if manifest_path not in names:
            raise SystemExit("ERROR: APK is missing " + manifest_path)

        manifest = {}
        for line in archive.read(manifest_path).decode("ascii").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  (?:\*)?([A-Za-z0-9._-]+)", line)
            if not match:
                raise SystemExit("ERROR: malformed checksum entry in " + manifest_path + ": " + repr(line))
            digest, filename = match.groups()
            if filename in manifest:
                raise SystemExit("ERROR: duplicate checksum for " + abi + "/" + filename)
            manifest[filename] = digest
        if set(manifest) != executables:
            raise SystemExit("ERROR: checksum manifest has unexpected entries for " + abi)

        for executable in sorted(executables):
            path = "assets/qemu/" + abi + "/" + executable
            if path not in names:
                raise SystemExit("ERROR: APK is missing " + path)
            data = archive.read(path)
            actual_sha256 = hashlib.sha256(data).hexdigest()
            if actual_sha256 != manifest[executable]:
                raise SystemExit("ERROR: SHA-256 mismatch for " + path)

            if len(data) < 64 or data[:4] != b"\x7fELF":
                raise SystemExit("ERROR: invalid ELF header in " + path)
            if data[4] != 2 or data[5] != 1:
                raise SystemExit("ERROR: " + path + " is not a 64-bit little-endian ELF")
            elf_type = struct.unpack_from("<H", data, 16)[0]
            machine = struct.unpack_from("<H", data, 18)[0]
            if elf_type != 3:
                raise SystemExit("ERROR: " + path + " is not a position-independent executable")
            if machine != expected_machine:
                raise SystemExit(
                    "ERROR: " + path + " has ELF machine " + str(machine) +
                    ", expected " + str(expected_machine)
                )

            phoff = struct.unpack_from("<Q", data, 32)[0]
            phentsize = struct.unpack_from("<H", data, 54)[0]
            phnum = struct.unpack_from("<H", data, 56)[0]
            if phentsize < 56 or phoff + phentsize * phnum > len(data):
                raise SystemExit("ERROR: invalid ELF program-header table in " + path)
            interpreter = None
            for index in range(phnum):
                offset = phoff + index * phentsize
                p_type, _, p_offset, _, _, p_filesz, _, _ = struct.unpack_from(
                    "<IIQQQQQQ", data, offset
                )
                if p_type == 3:
                    if p_offset + p_filesz > len(data):
                        raise SystemExit("ERROR: invalid PT_INTERP segment in " + path)
                    interpreter = data[p_offset:p_offset + p_filesz].split(b"\0", 1)[0].decode()
                    break
            if interpreter != "/system/bin/linker64":
                raise SystemExit(
                    "ERROR: " + path + " uses interpreter " + repr(interpreter) +
                    ", expected /system/bin/linker64"
                )
            print("OK: " + path + " (ELF machine " + str(machine) + ", SHA-256 verified, Android linker)")

print("APK QEMU runtime packaging, checksum, and ELF verification passed.")
PY
