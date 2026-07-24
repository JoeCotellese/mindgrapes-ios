# Handoff: Slices 2–4 (photo, location, Siri intents)

Built autonomously in one session, local commits only (no pushes, no PRs), each
slice adversarially reviewed by three independent agents before merge. This
records what landed, what is verified, and what needs your hands-on (HITL) check.

## What's on `main`

Merge commits, oldest first:
- `5533aac` Slice 2 — photo capture end-to-end
- `190770c` Slice 3 — location capture
- `b68c7f8` Slice 4 — Siri + Shortcuts capture intents

`MindGrapesKit`: **252 tests pass** (`make test`). The app **builds for the
simulator** (`make build`). Nothing was pushed; merge or push when you're ready.

## Slice 2 — Photo capture

- `PhotoSpooler`: downscales captured bytes (reusing `ImageDownscaler`) and
  writes the one JPEG derivative to the App Group spool.
- `CaptureQueue.imageMultipartBody(id:)` reads the spool and encodes; a missing
  file is terminal (`spoolFileMissing`), a present-but-unreadable file is
  transient (propagates, record stays reclaimable).
- `CaptureQueue.markUnsendable` + `prune` now reclaims terminally-failed photos'
  spool files past the 7-day window (bounds disk growth).
- `NoteDrainer` renamed `CaptureDrainer`, with a photo branch; a photo that can't
  encode fails only itself, without aborting the pass.
- `PhotoDescription.template` — timestamp fallback until Slice 6's OCR/model.
- UI: `PhotosPicker` (out-of-process, no permission prompt) + a camera sheet
  (`CameraPicker`), `NSCameraUsageDescription` added.

## Slice 3 — Location

- `LocationProvider`: one-shot fix under a per-stage time budget, with non-fatal
  reverse geocoding. A coordinate with no label is still a fix; only a missing
  coordinate is no fix.
- `SystemLocationProvider` (iOS only): `CLLocationManager` one-shot bridged to
  async and `CLGeocoder`, **both cancellation-aware** so the budget actually
  binds on device (a review caught that the first cut's budget silently didn't).
- `LocationPermission`: reads authorization without starting a request.
- UI: an "Include location" toggle backed by shared defaults; notes carry
  lat/lng/place_label, photos carry lat/lng; a denied permission flips the toggle
  off with one explanation. `NSLocationWhenInUseUsageDescription` added.

## Slice 4 — Siri + Shortcuts

- `CaptureIntentRunner` (the tested pipeline): validate → enqueue durably →
  attempt one upload under a 10s budget → report an outcome. Offline returns
  `.queued` with a durable record; a terminal reject returns `.failed`; a dead
  refresh returns `.needsSignIn`.
- `CaptureNoteIntent` (voice-first), `CapturePhotoIntent` (Shortcuts file input),
  `OpenCaptureIntent`, and `MindGrapesShortcuts` phrases.
- `AppComposition`: **one process-wide** graph (container, queue, refresher),
  built with no network call so offline capture still enqueues. This was the big
  review find — a per-call graph risked a CoreData segfault, double-delivered
  experiences (two drain gates), and a family-revocation sign-out (two refreshers).
- The capture screen now runs the **same** `CaptureIntentRunner` as Siri.

## Review findings folded in (highlights)

- Slice 2: spool leak on terminal failure; read-failure misclassification;
  the note field being hijacked by a photo tap; camera silent no-op.
- Slice 3: **the location budget didn't bind on device** — `withTaskGroup` awaits
  all children and the CoreLocation continuations weren't cancellation-aware;
  fixed with `withTaskCancellationHandler`.
- Slice 4: shared composition (segfault / double-delivery / single-refresher),
  terminal/auth outcomes reported honestly, orphaned-spool cleanup, drain-cancel
  no longer force-fails the backlog.

## What is NOT verified — your HITL checklist

Everything below compiles but was not exercised (no simulator/device/live server
in this session):

1. **Photo capture, sim + device.** Pick a library photo and shoot a camera photo
   (camera is device-only). Confirm a row in `brain.experiences` with an
   attachments row and a blob, `metadata.source = "app"`.
2. **Location.** With the toggle on, confirm a note row carries lat/lng and a
   place_label, and a photo row carries lat/lng. Deny permission once and confirm
   the toggle flips off with the explanation and does not nag.
3. **Siri.** "Hey Siri, capture a thought in MindGrapes" → dictate → confirm
   "Saved." and a server row. Try it in airplane mode → "Saved, it'll sync" and a
   durable record that drains on reconnect.
4. **Shortcuts.** Run `Capture a Photo` from the Shortcuts app with an image
   input; confirm the server row.
5. **Sign-in still works** end-to-end against the dev server after the CaptureView
   refactor (it now reads the persisted server config, no threaded base URL).
6. **The keychain -34018 path** on device is unchanged (still `accessGroup: nil`).

## Known rough edges (deliberate, documented in code)

- The Slice-1/2 drain loop and both screens are throwaway (issues 16/17 replace
  them). Slice 5's background transport replaces `CaptureDrainer` wholesale.
- `CaptureView.drain()` (launch/foreground flush) has no time budget, so a dead-
  but-hanging network could hold the UI busy up to URLSession's own timeout (~60s).
  Fine for a HITL scaffold.
- `CLGeocoder` is deprecated on iOS 26 (MapKit is the replacement); it still works
  and the label is best-effort. Left with a ponytail note.
- Siri captures attach no location yet (getting a fix from a background intent
  needs care); the toggle-driven location is the screen's path.
- `AppComposition` caches on nothing, so a mid-session re-onboard to a different
  server would be stale. There is no re-onboard flow yet; clear the cache when
  Slice 7 adds sign-out / change-server.

## Suggested next

- **Slice 5 (background transport, #6):** the reconciliation logic is
  loop-verifiable, but the real background `URLSession` handoff is device-verified
  and fiddly — best done with you in the loop.
- **Slice 6 (OCR + on-device description, #12/#13):** the protocol seams, fake,
  and template fallback are loop-verifiable now; the real Vision/Foundation Models
  paths are device/sim.
- **Slice 7:** real onboarding/capture/settings screens and the eight-condition
  verification gate — mostly sim/device/server.
