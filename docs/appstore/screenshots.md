<!-- ABOUTME: What App Store Connect requires for MindGrapes screenshots and exactly how to shoot them. -->
<!-- ABOUTME: No screenshots exist yet; this is the shot list and the blocker that stops it being automated. -->

# Screenshots — MindGrapes

**Status: none captured. This is outstanding work, not a solved problem.**

Verified 2026-07-27 against Apple's
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/).
Apple's requirements move; recheck that page before shooting rather than
trusting these numbers.

## What App Store Connect requires

Apple scales down from the largest size you supply, so one size per platform is
enough. All three platforms below are required, because the app record covers
iPhone, iPad, and a bundled watch app.

- **iPhone, 6.9"** — 1320 x 2868 portrait (2868 x 1320 landscape). Required.
  Devices: iPhone 17 Pro Max, 16 Pro Max, 15 Pro Max, 14 Pro Max. If 6.9" is
  not supplied, Apple falls back to requiring 6.5" (1284 x 2778); supplying 6.9"
  is simpler and covers everything below it.
- **iPad, 13"** — 2064 x 2752 portrait (2752 x 2064 landscape). Required.
  Devices: iPad Pro (M4/M5), iPad Air 13-inch (M2/M3/M4).
- **Apple Watch** — required because a watch app is embedded. One size, from the
  largest model you can boot; Apple Watch Ultra 3 (49mm) is 422 x 514.

Rules that reject an upload: 1 to 10 images per localization, `.png`/`.jpg`
only, and **no alpha channel**. `xcrun simctl io screenshot` writes RGBA PNGs,
so strip alpha before uploading:

```sh
sips -s format png --setProperty hasAlpha false shot.png --out shot-flat.png
```

Portrait for all three. The iPad target declares all four orientations, but a
portrait set matches how the app is actually used and avoids shooting twice.

## The blocker: the app is a login wall without a server

This is why there are no screenshots in the repo, and it is the same problem as
the App Review demo account in `listing.md`.

`RootView` shows `ConnectView` until the Keychain holds a usable token, and
getting a token means completing OAuth against a reachable Mind Grapes server.
Nothing about that can be faked from `simctl`. So every screen worth showing —
capture, the location toggle, settings, the watch's status line — is behind a
sign-in that a screenshot script cannot get through.

A connect-screen-only screenshot set is worse than useless: Apple's own guidance
is that screenshots should show the app in use, and a product page whose first
image is a sign-in form converts badly on top of that.

**So the real prerequisite is a reachable server to shoot against**, publicly
resolvable rather than Tailscale-only. Stand that up for App Review and the
screenshots come free from the same instance.

## What was verified to work

The pipeline itself is fine. Signed in, this produces real shots:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # iOS 27 SDK
make build
APP=~/Library/Developer/Xcode/DerivedData/MindGrapes-*/Build/Products/Debug-iphonesimulator/MindGrapes.app

xcrun simctl boot "iPhone 17 Pro"
xcrun simctl bootstatus "iPhone 17 Pro"
xcrun simctl install "iPhone 17 Pro" "$APP"
xcrun simctl launch "iPhone 17 Pro" net.cotellese.mindgrapes
xcrun simctl io "iPhone 17 Pro" screenshot shot.png
```

Confirmed on 2026-07-27: installs, launches, and writes a 1206 x 2622 PNG of the
connect screen. `DEVELOPER_DIR` is load-bearing — the released Xcode's
simulators run iOS 26 and the install fails with "Requires a Newer Version of
iOS", since the app's floor is iOS 27.

## The devices are not installed yet

Only these exist on iOS 27 right now: iPhone 17 Pro, iPad mini (A17 Pro), iPad
Air 13-inch (M4), iPad (A16). **iPhone 17 Pro shoots 1206 x 2622, which is not
the required 6.9" size,** and there is no watchOS 27 device at all.

The device types and runtimes are both present, so this is one `simctl create`
each, not a download:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun simctl create "Shots 6.9" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max \
  com.apple.CoreSimulator.SimRuntime.iOS-27-0
xcrun simctl create "Shots Watch" \
  com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm \
  com.apple.CoreSimulator.SimRuntime.watchOS-27-0
```

iPad Air 13-inch (M4) on iOS 27 already exists and is a valid 13" iPad, so it
needs no new device.

The watch app is embedded in the phone bundle and installs onto a *paired*
watch, so pair the two before installing, or use the existing "iPhone 17 Pro +
Watch" pair as the model:

```sh
xcrun simctl pair "Shots Watch" "Shots 6.9"
```

## Shot list

Five images, in this order. The first is the one most people see, so it carries
the qualifier.

1. **Connect / onboarding.** The screen that says "Your memories live on your
   own server." This is the only honest way to lead: it makes an unqualified
   buyer bounce before installing. Caption it with the requirement.
2. **Capture, mid-note.** Text in the field, "Include location" visible, the
   status line showing a real state. This is the app's whole product.
3. **Photo capture.** A photo picked or shot, with the generated description
   showing. Shoot a product label so the on-device description does something
   visible — the dog-food-label case from `docs/PHASE1-ISSUES.md`, which is what
   the OCR-plus-model path exists for.
4. **Siri.** "Hey Siri, capture a thought in Mind Grapes" with the confirmation.
   The hands-free path is a real differentiator and it does not show up in any
   static screen. Needs a device, not a simulator: Siri does not run there.
5. **Settings.** Server address and sign-out. Short, and it proves there is no
   account with the developer.

For iPad, shots 1 through 3 are enough. For the watch, one shot: the capture
button with the status line under it.

Add caption text overlays before uploading. Bare simulator captures with no
caption convert worse than framed ones, and the qualifier ("needs your own
server") should be legible in image 1 without reading the description.

## Automation

Not worth building. Five images, once per release at most, gated on a manual
sign-in that no script can perform. `fastlane snapshot` would need a UI test
target, and there is no app test target at all (issue #24). Shoot them by hand.
