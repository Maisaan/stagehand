#!/bin/bash
set -euo pipefail

stagehand_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$stagehand_root"

swift build -c release -Xswiftc -Osize
stagehand_bin="$(swift build -c release -Xswiftc -Osize --show-bin-path)"
stagehand_bundle="$stagehand_root/dist/Stagehand.app"
mkdir -p "$stagehand_bundle/Contents/MacOS" "$stagehand_bundle/Contents/Resources"
install -m 755 "$stagehand_bin/Stagehand" "$stagehand_bundle/Contents/MacOS/Stagehand"
install -m 644 "$stagehand_root/Resources/Info.plist" "$stagehand_bundle/Contents/Info.plist"
install -m 644 "$stagehand_root/Resources/Stagehand.icns" "$stagehand_bundle/Contents/Resources/Stagehand.icns"
install -m 644 "$stagehand_root/Resources/StagehandMenuBar.svg" "$stagehand_bundle/Contents/Resources/StagehandMenuBar.svg"
rm -rf "$stagehand_bundle/Contents/Resources/Phosphor"
cp -R "$stagehand_root/Sources/Stagehand/Resources/Phosphor" "$stagehand_bundle/Contents/Resources/Phosphor"

# SwiftPM keeps local and debug symbols in release executables. They are useful in
# the build directory, but add no runtime value to the installed application.
strip -x "$stagehand_bundle/Contents/MacOS/Stagehand"

# Accessibility permission follows the code signature. A stable identity keeps the
# grant across rebuilds; an ad-hoc signature changes every time. Prefer an explicit
# STAGEHAND_SIGNING_IDENTITY, then a local Apple Development certificate, then ad-hoc.
# None of these produce a notarized distribution build.
stagehand_signing_identity="${STAGEHAND_SIGNING_IDENTITY:-}"
if [[ -z "$stagehand_signing_identity" ]]; then
    stagehand_signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"Apple Development: / { print $2; exit }')"
fi
stagehand_signing_identity="${stagehand_signing_identity:--}"
codesign --force --sign "$stagehand_signing_identity" "$stagehand_bundle"
codesign --verify --strict "$stagehand_bundle"
printf 'Built %s\nSigned with: %s\n' "$stagehand_bundle" "$stagehand_signing_identity"
if [[ "$stagehand_signing_identity" == "-" ]]; then
    printf 'Warning: this ad-hoc signature changes on rebuild; macOS will require Accessibility again after replacement.\n'
fi
printf 'Open with: open "%s"\n' "$stagehand_bundle"
