#!/bin/bash
set -euo pipefail
# Builds the disposable app that --acceptance launches. It needs no permissions.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$root/dist/AcceptanceProbe.app"
mkdir -p "$bundle/Contents/MacOS"
swiftc -O -o "$bundle/Contents/MacOS/AcceptanceProbe" "$root/scripts/AcceptanceProbe.swift"
install -m 644 "$root/scripts/AcceptanceProbe-Info.plist" "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
printf 'Built %s\n' "$bundle"
