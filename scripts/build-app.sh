#!/bin/bash
set -euo pipefail

stagehand_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$stagehand_root"

# The sources use `isolated deinit`, which needs Swift 6.2 (Xcode 26). An older
# toolchain fails deep inside the build with an unhelpful parse error, so check first.
stagehand_minimum_swift="6.2"
stagehand_swift_version="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1)"
if [[ -z "$stagehand_swift_version" ]]; then
    printf 'Could not determine the Swift version from "swift --version". Stagehand needs Swift %s or newer.\n' \
        "$stagehand_minimum_swift" >&2
    exit 1
fi
if [[ "$(printf '%s\n%s\n' "$stagehand_minimum_swift" "$stagehand_swift_version" | sort -V | head -n 1)" != "$stagehand_minimum_swift" ]]; then
    printf 'Swift %s is too old. Stagehand needs Swift %s or newer (Xcode 26 or newer).\n' \
        "$stagehand_swift_version" "$stagehand_minimum_swift" >&2
    exit 1
fi

swift build -c release -Xswiftc -Osize
stagehand_bin="$(swift build -c release -Xswiftc -Osize --show-bin-path)"
stagehand_bundle="$stagehand_root/dist/Stagehand.app"
# Start from an empty bundle so files removed from the source tree are not signed
# into the new build.
rm -rf "$stagehand_bundle"
mkdir -p "$stagehand_bundle/Contents/MacOS" "$stagehand_bundle/Contents/Resources"
install -m 755 "$stagehand_bin/Stagehand" "$stagehand_bundle/Contents/MacOS/Stagehand"
install -m 644 "$stagehand_root/Resources/Info.plist" "$stagehand_bundle/Contents/Info.plist"
install -m 644 "$stagehand_root/Resources/Stagehand.icns" "$stagehand_bundle/Contents/Resources/Stagehand.icns"
install -m 644 "$stagehand_root/Resources/StagehandMenuBar.svg" "$stagehand_bundle/Contents/Resources/StagehandMenuBar.svg"
cp -R "$stagehand_root/Sources/Stagehand/Resources/Phosphor" "$stagehand_bundle/Contents/Resources/Phosphor"
if [[ -z "$(find "$stagehand_bundle/Contents/Resources/Phosphor" -name '*.svg' -print -quit)" ]]; then
    printf 'No Phosphor icons were copied into %s.\n' "$stagehand_bundle/Contents/Resources/Phosphor" >&2
    exit 1
fi

# Resources/Info.plist stays a template. Stamp the installed copy with the git
# description so a running build can be matched to a commit. A checkout without
# git history keeps the template values.
stagehand_plist="$stagehand_bundle/Contents/Info.plist"
stagehand_short_version="$(git describe --tags --always --dirty 2>/dev/null || true)"
stagehand_build_number="$(git rev-list --count HEAD 2>/dev/null || true)"
if [[ -n "$stagehand_short_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $stagehand_short_version" "$stagehand_plist"
fi
if [[ -n "$stagehand_build_number" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $stagehand_build_number" "$stagehand_plist"
fi
stagehand_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stagehand_plist")"
stagehand_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$stagehand_plist")"

# SwiftPM keeps local and debug symbols in release executables. They are useful in
# the build directory, but add no runtime value to the installed application.
strip -x "$stagehand_bundle/Contents/MacOS/Stagehand"

# Accessibility permission follows the code signature. A stable identity keeps the
# grant across rebuilds; an ad-hoc signature changes every time. Prefer an explicit
# STAGEHAND_SIGNING_IDENTITY, then the self-signed identity from
# scripts/create-signing-identity.sh, then a local Apple Development certificate,
# then ad-hoc. None of these produce a notarized distribution build.
stagehand_signing_identity="${STAGEHAND_SIGNING_IDENTITY:-}"
if [[ -z "$stagehand_signing_identity" ]] &&
    security find-identity -v -p codesigning | grep -qF '"Stagehand Local Code Signing"'; then
    stagehand_signing_identity="Stagehand Local Code Signing"
fi
if [[ -z "$stagehand_signing_identity" ]]; then
    stagehand_signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"Apple Development: / { print $2; exit }')"
fi
stagehand_signing_identity="${stagehand_signing_identity:--}"
codesign --force --sign "$stagehand_signing_identity" "$stagehand_bundle"
codesign --verify --deep --strict "$stagehand_bundle"
printf 'Built %s\nVersion: %s (%s)\nSigned with: %s\n' \
    "$stagehand_bundle" "$stagehand_short_version" "$stagehand_build_number" "$stagehand_signing_identity"
if [[ "$stagehand_signing_identity" == "-" ]]; then
    printf 'Warning: this ad-hoc signature changes on rebuild; macOS will require Accessibility again after replacement.\n'
    printf 'Run scripts/create-signing-identity.sh once for a stable local signature.\n'
fi
printf 'Open with: open "%s"\n' "$stagehand_bundle"
