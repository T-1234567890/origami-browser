#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tool="$(mktemp -d)"
trap 'rm -rf "$tool"' EXIT
swiftc "$root/Origami/Updates/ReleaseIdentity.swift" "$root/scripts/release/VersionTool.swift" -o "$tool/version"
"$tool/version" "$@"
