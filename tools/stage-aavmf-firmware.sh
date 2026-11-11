#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE_VERSION=2026.08+ds-2
readonly PACKAGE_NAME=qemu-efi-aarch64_${PACKAGE_VERSION}_all.deb
readonly PACKAGE_URL=https://deb.debian.org/debian/pool/main/e/edk2/${PACKAGE_NAME}
readonly PACKAGE_SHA256=30467a3593c099ea42bd6ff3c4590e4b205edf9a7b98844f4bed17cd8b05eb58
readonly WORK_DIR=.work/aavmf
readonly DESTINATION=app/src/main/assets/firmware/edk2-${PACKAGE_VERSION}

mkdir -p ${WORK_DIR} ${DESTINATION} app/src/main/assets/licenses
curl --fail --location --retry 3 --retry-delay 2 ${PACKAGE_URL} --output ${WORK_DIR}/${PACKAGE_NAME}
echo "${PACKAGE_SHA256}  ${WORK_DIR}/${PACKAGE_NAME}" | sha256sum --check --strict

rm -rf ${WORK_DIR}/root
mkdir -p ${WORK_DIR}/root
dpkg-deb --extract ${WORK_DIR}/${PACKAGE_NAME} ${WORK_DIR}/root

readonly CODE_SOURCE=${WORK_DIR}/root/usr/share/AAVMF/AAVMF_CODE.fd
readonly VARS_SOURCE=${WORK_DIR}/root/usr/share/AAVMF/AAVMF_VARS.fd
readonly COPYRIGHT_SOURCE=${WORK_DIR}/root/usr/share/doc/qemu-efi-aarch64/copyright
readonly README_SOURCE=${WORK_DIR}/root/usr/share/doc/qemu-efi-aarch64/README.Debian
for required in "${CODE_SOURCE}" "${VARS_SOURCE}" "${COPYRIGHT_SOURCE}" "${README_SOURCE}"; do
  [[ -s "${required}" ]] || { echo "Missing required AAVMF package file: ${required}" >&2; exit 1; }
done

readonly EXPECTED_FIRMWARE_SIZE=$((64 * 1024 * 1024))
[[ $(stat -c %s "${CODE_SOURCE}") == ${EXPECTED_FIRMWARE_SIZE} ]]
[[ $(stat -c %s "${VARS_SOURCE}") == ${EXPECTED_FIRMWARE_SIZE} ]]

install -m 0644 "${CODE_SOURCE}" "${DESTINATION}/AAVMF_CODE.fd"
install -m 0644 "${VARS_SOURCE}" "${DESTINATION}/AAVMF_VARS.fd"
install -m 0644 "${README_SOURCE}" "${DESTINATION}/README.Debian"
install -m 0644 "${COPYRIGHT_SOURCE}" app/src/main/assets/licenses/edk2-aarch64-copyright.txt
(
  cd "${DESTINATION}"
  sha256sum AAVMF_CODE.fd AAVMF_VARS.fd > SHA256SUMS
  sha256sum --check --strict SHA256SUMS
)
echo Staged-AAVMF-${PACKAGE_VERSION}-64MiB-CODE-VARS-and-license-notices
