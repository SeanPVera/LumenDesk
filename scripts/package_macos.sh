#!/bin/bash
#
# Build a distributable macOS LumenDesk.app and wrap it in a DMG.
#
# The script uses nothing but the tooling that ships with Xcode and macOS
# (xcodebuild, codesign, hdiutil, notarytool, stapler), so it has the same
# zero-dependency posture as the app itself.
#
# It runs in three escalating modes and picks the highest one your
# environment supports:
#
#   unsigned    No signing credentials. Produces an ad-hoc signed app that
#               launches on the machine that built it. Gatekeeper blocks it
#               on every other Mac.
#   signed      SIGNING_IDENTITY + TEAM_ID present. Produces a Developer ID
#               signed app and DMG. Gatekeeper still quarantines a fresh
#               download until the ticket is checked.
#   notarized   Signing plus notary credentials. Submits to Apple, staples
#               the ticket to both the app and the DMG, and the result opens
#               with a double-click on any Mac, online or offline.
#
# See DISTRIBUTION.md for the credential setup.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="LumenDesk.xcodeproj"
SCHEME="LumenDesk"
APP_NAME="LumenDesk"
BUNDLE_ID="com.lumendesk.LumenDesk"

VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

usage() {
    cat <<'USAGE'
Usage: scripts/package_macos.sh [options]

Options:
  --version X.Y.Z     Marketing version. Defaults to the current git tag,
                      falling back to MARKETING_VERSION in the project.
  --build N           Build number. Defaults to the commit count.
  --output DIR        Where to write the DMG. Defaults to ./dist.
  --skip-notarize     Sign but do not submit to Apple.
  -h, --help          Show this message.

Environment:
  SIGNING_IDENTITY    Codesign identity, e.g. "Developer ID Application: Jane
                      Doe (ABCDE12345)". Auto-detected from the keychain when
                      unset.
  TEAM_ID             Apple Developer team identifier.
  NOTARY_KEY_PATH     App Store Connect API key (.p8). Preferred.
  NOTARY_KEY_ID       API key identifier.
  NOTARY_ISSUER_ID    API key issuer UUID.
  NOTARY_APPLE_ID     Apple ID, for the app-specific-password path instead.
  NOTARY_PASSWORD     App-specific password for that Apple ID.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD_NUMBER="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. This script needs Xcode on macOS."

# ---------------------------------------------------------------------------
# Version resolution
# ---------------------------------------------------------------------------

if [[ -z "$VERSION" ]]; then
    TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
    if [[ -n "$TAG" ]]; then
        VERSION="${TAG#v}"
    else
        VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
            -showBuildSettings -configuration Release 2>/dev/null \
            | awk '/ MARKETING_VERSION = /{print $3; exit}')"
    fi
fi
[[ -n "$VERSION" ]] || die "Could not resolve a version. Pass --version."

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
fi

# ---------------------------------------------------------------------------
# Signing mode
# ---------------------------------------------------------------------------

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -n 1 \
        | sed -n 's/.*"\(.*\)".*/\1/p' || true)"
fi

if [[ -n "$SIGNING_IDENTITY" && -z "$TEAM_ID" ]]; then
    # "Developer ID Application: Jane Doe (ABCDE12345)" -> ABCDE12345
    TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$SIGNING_IDENTITY")"
fi

MODE="unsigned"
if [[ -n "$SIGNING_IDENTITY" && -n "$TEAM_ID" ]]; then
    MODE="signed"
fi

NOTARY_ARGS=()
if [[ "$MODE" == "signed" && "$SKIP_NOTARIZE" != "1" ]]; then
    if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
        NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
        MODE="notarized"
    elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM_ID")
        MODE="notarized"
    fi
fi

log "LumenDesk $VERSION ($BUILD_NUMBER) — $MODE"
if [[ "$MODE" == "unsigned" ]]; then
    warn "No Developer ID identity found. The result runs on this Mac only."
elif [[ "$MODE" == "signed" ]]; then
    warn "Signing without notarization. Downloads on other Macs will be blocked."
fi

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lumendesk-package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_PATH="$WORK_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$WORK_DIR/export"

ARCHIVE_SETTINGS=(
    "MARKETING_VERSION=$VERSION"
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
)

if [[ "$MODE" == "unsigned" ]]; then
    # arm64 refuses to execute a binary with no signature at all, so ad-hoc
    # sign rather than passing CODE_SIGNING_ALLOWED=NO.
    ARCHIVE_SETTINGS+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=-"
        "CODE_SIGNING_REQUIRED=NO"
        "DEVELOPMENT_TEAM="
        "PROVISIONING_PROFILE_SPECIFIER="
    )
else
    ARCHIVE_SETTINGS+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
        "DEVELOPMENT_TEAM=$TEAM_ID"
        "PROVISIONING_PROFILE_SPECIFIER="
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
fi

log "Archiving"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    "${ARCHIVE_SETTINGS[@]}"

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

mkdir -p "$EXPORT_DIR"

if [[ "$MODE" == "unsigned" ]]; then
    # exportArchive has no meaningful Developer ID output without an identity,
    # so lift the app straight out of the archive.
    log "Extracting app from archive"
    cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_DIR/"
else
    log "Exporting signed app"
    cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>destination</key>
    <string>export</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$WORK_DIR/ExportOptions.plist"
fi

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || die "Export produced no $APP_NAME.app"

log "Verifying signature"
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign --display --entitlements :- "$APP_PATH" >/dev/null

# ---------------------------------------------------------------------------
# Notarize the app, then staple, so it validates with no network
# ---------------------------------------------------------------------------

if [[ "$MODE" == "notarized" ]]; then
    log "Notarizing app"
    APP_ZIP="$WORK_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"

    # The point of the whole exercise: confirm Gatekeeper will let this run
    # on a Mac that has never seen it before.
    log "Assessing with Gatekeeper"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

# ---------------------------------------------------------------------------
# DMG
# ---------------------------------------------------------------------------

log "Building disk image"
mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"

STAGE_DIR="$WORK_DIR/dmg"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH"

if [[ "$MODE" != "unsigned" ]]; then
    log "Signing disk image"
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ "$MODE" == "notarized" ]]; then
    log "Notarizing disk image"
    xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH" | awk '{print $1}' > "$DMG_PATH.sha256"

log "Done"
printf '  %s\n' "$DMG_PATH"
printf '  sha256 %s\n' "$(cat "$DMG_PATH.sha256")"
printf '  mode   %s\n' "$MODE"

if [[ "$MODE" != "notarized" ]]; then
    cat <<'HINT'

Because this build is not notarized, macOS will refuse to open it after a
download. Clear the quarantine flag on the receiving Mac:

    xattr -dr com.apple.quarantine /Applications/LumenDesk.app
HINT
fi
