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

# SwiftPM keeps local and debug symbols in release executables. They are useful in
# the build directory, but add no runtime value to the installed application.
strip -x "$stagehand_bundle/Contents/MacOS/Stagehand"

# For repeat development builds, provide a stable local signing identity if you have one.
# The default is an ad-hoc development signature, not a notarized distribution build.
stagehand_signing_identity="${STAGEHAND_SIGNING_IDENTITY:--}"
codesign --force --sign "$stagehand_signing_identity" "$stagehand_bundle"
codesign --verify --strict "$stagehand_bundle"
printf 'Built %s\n' "$stagehand_bundle"
if [[ "$stagehand_signing_identity" == "-" ]]; then
    printf 'Warning: this ad-hoc signature changes on rebuild; macOS will require Accessibility again after replacement.\n'
fi
printf 'Open with: open "%s"\n' "$stagehand_bundle"
