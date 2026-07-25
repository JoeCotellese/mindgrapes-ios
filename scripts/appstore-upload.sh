#!/bin/sh
# ABOUTME: Archives the app, exports a signed IPA, and ships it to App Store Connect.
# ABOUTME: Every credential comes from the environment, so nothing secret is ever committed.

# App Store Connect authentication is maintainer-only: a contributor never runs
# this. The three ASC_* values come from an API key you create at
# https://appstoreconnect.apple.com/access/integrations/api. DEVELOPMENT_TEAM is
# your ten-character Apple Developer Team ID, needed to sign the export.
#
# Load them however you like; the repo ships a `.env.example` to copy:
#   set -a; . ./.env; set +a; ./scripts/appstore-upload.sh
#
# Set VALIDATE=1 to run App Store Connect's validation without submitting. Do
# that first: it catches almost everything a real upload would reject, and it
# does not consume a build number or notify anyone.

set -eu

fail() {
    echo "error: $1" >&2
    exit 1
}

require() {
    # POSIX indirect expansion without bashisms.
    eval "value=\${$1:-}"
    [ -n "$value" ] || fail "$1 is not set. Copy .env.example to .env and fill it in, or export it."
}

require ASC_KEY_ID
require ASC_ISSUER_ID
require ASC_KEY_PATH
require DEVELOPMENT_TEAM

[ -f "$ASC_KEY_PATH" ] || fail "ASC_KEY_PATH points at no file: $ASC_KEY_PATH"

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found. brew install xcodegen."

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build/release"
ARCHIVE="$BUILD_DIR/MindGrapes.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

# altool locates the key by name, not path: it wants AuthKey_<key-id>.p8 in a
# directory it searches. Give it a private temp directory rather than copying a
# secret into the tree or the home folder, and remove it on the way out however
# the script exits.
KEY_DIR=$(mktemp -d)
cleanup() { rm -rf "$KEY_DIR"; }
trap cleanup EXIT
cp "$ASC_KEY_PATH" "$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
export API_PRIVATE_KEYS_DIR="$KEY_DIR"

# The team is injected here rather than committed in an ExportOptions.plist,
# which keeps an account identifier out of a public repo. Automatic signing lets
# each maintainer's own distribution profile satisfy the export.
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"

# App Store Connect rejects a duplicate build number, so every upload needs a
# fresh one. The git commit count is monotonic and needs no committed state to
# bump; set BUILD_NUMBER to override (e.g. to re-upload the same commit after an
# ASC-side deletion). This overrides project.yml's CURRENT_PROJECT_VERSION at
# archive time.
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[ -n "$BUILD" ] || fail "could not compute a build number (git rev-list failed)"

echo "==> Regenerating the project"
make generate >/dev/null

echo "==> Archiving build $BUILD"
rm -rf "$ARCHIVE"
mkdir -p "$BUILD_DIR"
xcodebuild archive \
    -project MindGrapes.xcodeproj \
    -scheme MindGrapes \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CURRENT_PROJECT_VERSION="$BUILD"

cat >"$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "==> Exporting the IPA"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR"

IPA=$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -1)
[ -n "$IPA" ] || fail "no IPA produced under $EXPORT_DIR"

if [ "${VALIDATE:-0}" = "1" ]; then
    echo "==> Validating $IPA (no submission)"
    ACTION="--validate-app"
else
    echo "==> Uploading $IPA to App Store Connect"
    ACTION="--upload-app"
fi

xcrun altool $ACTION \
    -f "$IPA" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"

echo "==> Done"
