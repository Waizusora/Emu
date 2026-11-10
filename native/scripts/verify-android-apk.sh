#!/usr/bin/env bash
# Verify that the generated APK contains the JNI bridge for every supported ABI.
# This checks packaging only; it does not claim that the QEMU engine is present.
set -euo pipefail

APK="${1:-app/build/outputs/apk/debug/app-debug.apk}"

# Fail with a clear message if the APK or unzip utility is unavailable.
if [[ ! -f "$APK" ]]; then
  echo "ERROR: APK not found: $APK" >&2
  exit 2
fi
command -v unzip >/dev/null 2>&1 || {
  echo "ERROR: unzip is required to inspect the APK" >&2
  exit 2
}

# Read the archive index once and confirm the native bridge for each ABI.
CONTENTS="$(unzip -Z1 "$APK")"
for ABI in arm64-v8a x86_64; do
  LIBRARY="lib/$ABI/libemu-qemu.so"
  if ! grep -Fqx "$LIBRARY" <<< "$CONTENTS"; then
    echo "ERROR: APK is missing $LIBRARY" >&2
    exit 1
  fi
  echo "OK: $LIBRARY"
done

# Require license texts and attribution inventory to be present in the installed APK.
for LICENSE_ASSET in \
  assets/licenses/mit.txt \
  assets/licenses/apache-2.0.txt \
  assets/licenses/NOTICE.txt; do
  if ! grep -Fqx "$LICENSE_ASSET" <<< "$CONTENTS"; then
    echo "ERROR: APK is missing $LICENSE_ASSET" >&2
    exit 1
  fi
  echo "OK: $LICENSE_ASSET"
done

echo "APK ABI and open-source notice packaging verification passed: $APK"
