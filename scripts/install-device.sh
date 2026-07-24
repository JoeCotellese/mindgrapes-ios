#!/bin/sh
# ABOUTME: Builds a signed MindGrapes and installs it on a connected iPhone.
# ABOUTME: Signing comes from Signing.xcconfig.local; pick a device with DEVICE=.

# Unlike the simulator build, this needs a real signing identity. Set your Team
# ID in Signing.xcconfig.local first (see CONTRIBUTING "Building on a device").
# Choose the target with DEVICE, a name or identifier from `make devices`:
#
#     make device DEVICE="Development iPhone"
#
# LAUNCH=0 installs without starting the app.

set -eu

fail() {
    echo "error: $1" >&2
    exit 1
}

DEVICE="${DEVICE:-}"
[ -n "$DEVICE" ] || fail "set DEVICE to a device name or identifier. List them with: make devices"

BUNDLE_ID="net.cotellese.mindgrapes"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT"

DERIVED="$REPO_ROOT/build/device"
APP="$DERIVED/Build/Products/Debug-iphoneos/MindGrapes.app"

echo "==> Regenerating the project"
make generate >/dev/null

# -allowProvisioningUpdates lets automatic signing register the device and mint
# a development profile for the app's bundle id and entitlements on first run.
echo "==> Building signed for '$DEVICE'"
xcodebuild build \
    -project MindGrapes.xcodeproj \
    -scheme MindGrapes \
    -destination "platform=iOS,name=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates

[ -d "$APP" ] || fail "no app built at $APP"

echo "==> Installing on '$DEVICE'"
xcrun devicectl device install app --device "$DEVICE" "$APP"

if [ "${LAUNCH:-1}" = "1" ]; then
    echo "==> Launching"
    xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
fi

echo "==> Done"
