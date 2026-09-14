#!/bin/bash
set -euo pipefail

stagehand_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$stagehand_root"

swift build -c release
stagehand_bin="$(swift build -c release --show-bin-path)"
stagehand_bundle="$stagehand_root/dist/Stagehand.app"
mkdir -p "$stagehand_bundle/Contents/MacOS" "$stagehand_bundle/Contents/Resources"
install -m 755 "$stagehand_bin/Stagehand" "$stagehand_bundle/Contents/MacOS/Stagehand"
install -m 644 "$stagehand_root/Resources/Info.plist" "$stagehand_bundle/Contents/Info.plist"
install -m 644 "$stagehand_root/Resources/Stagehand.icns" "$stagehand_bundle/Contents/Resources/Stagehand.icns"

# For repeat development builds, provide a stable local signing identity if you have one.
# The default is an ad-hoc development signature, not a notarized distribution build.
codesign --force --sign "${STAGEHAND_SIGNING_IDENTITY:--}" "$stagehand_bundle"
codesign --verify --strict "$stagehand_bundle"
printf 'Built %s\n' "$stagehand_bundle"
printf 'Open with: open "%s"\n' "$stagehand_bundle"
