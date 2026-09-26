#!/bin/bash
set -euo pipefail
# Cloud's test VM cannot launch a host with profile-restricted entitlements.
# Change only its disposable build-for-testing checkout, never an archive.
if [[ "${CI:-}" != "TRUE" ]]; then
  exit 0
fi
case "${CI_XCODEBUILD_ACTION:-}" in
  build-for-testing|archive)
    python3 "${CI_PRIMARY_REPOSITORY_PATH:?}/scripts/release/cloud_test_entitlements.py"
    ;;
esac
