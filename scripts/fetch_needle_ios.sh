#!/usr/bin/env bash

set -euo pipefail

readonly NEEDLE_REVISION="17a803d95928ba33d3e9a0160e024d9565b5c3f2"
readonly NEEDLE_BASE_URL="https://huggingface.co/Cactus-Compute/needle2/resolve/${NEEDLE_REVISION}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
vendor_dir="${repo_root}/Vendor/Needle"
cache_dir="${repo_root}/artifacts/needle/${NEEDLE_REVISION}"
xcframework_path="${vendor_dir}/Needle.xcframework"
revision_stamp="${vendor_dir}/.artifact-revision"
checksums_path="${vendor_dir}/ARTIFACTS.sha256"

usage() {
  printf 'Usage: %s [--verify]\n' "$0"
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

expected_sha256() {
  local artifact_path="$1"
  awk -v artifact_path="${artifact_path}" '$2 == artifact_path { print $1 }' "${checksums_path}"
}

verify_file() {
  local file_path="$1"
  local expected="$2"
  local label="$3"

  if [[ ! -f "${file_path}" ]]; then
    printf 'Missing Needle artifact: %s\n' "${label}" >&2
    return 1
  fi

  local actual
  actual="$(sha256 "${file_path}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Checksum mismatch for %s\nexpected: %s\nactual:   %s\n' \
      "${label}" "${expected}" "${actual}" >&2
    return 1
  fi
}

download_artifact() {
  local artifact_path="$1"
  local expected
  expected="$(expected_sha256 "${artifact_path}")"
  if [[ -z "${expected}" ]]; then
    printf 'No checksum is pinned for %s\n' "${artifact_path}" >&2
    return 1
  fi

  local destination="${cache_dir}/${artifact_path}"
  if [[ -f "${destination}" ]] && verify_file "${destination}" "${expected}" "${artifact_path}"; then
    return
  fi

  mkdir -p "$(dirname "${destination}")"
  local temporary="${destination}.download"
  curl --fail --location --retry 3 --retry-all-errors \
    --output "${temporary}" \
    "${NEEDLE_BASE_URL}/${artifact_path}?download=true"
  verify_file "${temporary}" "${expected}" "${artifact_path}"
  mv "${temporary}" "${destination}"
}

verify_installation() {
  if [[ ! -f "${revision_stamp}" ]] || [[ "$(<"${revision_stamp}")" != "${NEEDLE_REVISION}" ]]; then
    printf 'Needle revision stamp is missing or stale. Run mise run needle:ios:fetch.\n' >&2
    return 1
  fi

  verify_file \
    "${xcframework_path}/ios-arm64/libneedle.a" \
    "$(expected_sha256 'ios-arm64/libneedle.a')" \
    "Needle.xcframework device library"
  verify_file \
    "${xcframework_path}/ios-arm64-simulator/libneedle.a" \
    "$(expected_sha256 'ios-sim-arm64/libneedle.a')" \
    "Needle.xcframework simulator library"
  verify_file \
    "${xcframework_path}/ios-arm64/Headers/needle.h" \
    "$(expected_sha256 'ios-arm64/needle.h')" \
    "Needle.xcframework header"
  if [[ ! -f "${xcframework_path}/ios-arm64/Headers/module.modulemap" ]] || \
     [[ ! -f "${xcframework_path}/ios-arm64-simulator/Headers/module.modulemap" ]]; then
    printf 'Needle C module maps are missing. Run mise run needle:ios:fetch.\n' >&2
    return 1
  fi

  printf 'Needle iOS artifacts verified at revision %s.\n' "${NEEDLE_REVISION}"
}

if [[ "${1:-}" == "--verify" ]]; then
  verify_installation
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 64
fi

for artifact_path in \
  ios-arm64/libneedle.a \
  ios-sim-arm64/libneedle.a \
  ios-arm64/needle.h; do
  download_artifact "${artifact_path}"
done

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/adspace-needle-ios.XXXXXX")"
cleanup() {
  rm -rf -- "${staging_dir}"
}
trap cleanup EXIT

mkdir -p \
  "${staging_dir}/device-headers" \
  "${staging_dir}/simulator-headers"

cp "${cache_dir}/ios-arm64/needle.h" "${staging_dir}/device-headers/needle.h"
cp "${cache_dir}/ios-arm64/needle.h" "${staging_dir}/simulator-headers/needle.h"
cp "${vendor_dir}/module.modulemap" "${staging_dir}/device-headers/module.modulemap"
cp "${vendor_dir}/module.modulemap" "${staging_dir}/simulator-headers/module.modulemap"

xcodebuild -create-xcframework \
  -library "${cache_dir}/ios-arm64/libneedle.a" \
  -headers "${staging_dir}/device-headers" \
  -library "${cache_dir}/ios-sim-arm64/libneedle.a" \
  -headers "${staging_dir}/simulator-headers" \
  -output "${staging_dir}/Needle.xcframework"

rm -rf -- "${xcframework_path}"
mv "${staging_dir}/Needle.xcframework" "${xcframework_path}"
printf '%s\n' "${NEEDLE_REVISION}" > "${revision_stamp}"

verify_installation
