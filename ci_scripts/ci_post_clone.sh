#!/bin/bash
# Xcode Cloud discovers this hook. Signing and notarization remain Cloud actions.
set -euo pipefail
cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}"
if [[ -z "${CI_TAG:-}" ]]; then
  if [[ "${CI_WORKFLOW:-}" == "Release" ]]; then
    echo 'The Release workflow requires a release tag.' >&2; exit 1
  fi
  exit 0
fi
python3 scripts/release/cloud_configuration.py
