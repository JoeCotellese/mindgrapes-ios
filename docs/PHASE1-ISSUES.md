# MindGrapes iOS: Phase 1 work breakdown

Companion to `SPEC.md`. Phase 1 is defined in SPEC section 12: a phone can be
onboarded to a Mind Grapes server and reliably capture text and photos from
the app, offline included.

This plan is organized around **vertical slices**. Each slice delivers
something the primary user (Joe) can actually use end to end, even if rough
around the edges, rather than a horizontal layer that is invisible until the
layer above it lands. The numbered **item catalog** further down is preserved
as the unit of PR work: each item is still one branch and one PR, and each
slice names the items it draws on. "Thin" next to an item means only the named
subset of that item is needed for the slice.

## Verification modes

- **`loop`**: verifiable by `swift test` on the `MindGrapesKit` package. No
  simulator, no server, no device, no network. These can be built
  unattended against a failing test.
- **`sim`**: needs an iOS simulator (UI, system frameworks, XCUITest).
- **`device`**: needs real hardware (camera, Apple Intelligence, background
  session behavior under real scheduling).
- **`server`**: needs the dev stack up (`make dev-up` in the server repo),
  and in some cases a server PR merged first.

## Build status (2026-07-24)

Done and merged to `main`. Loop items are `loop`-verified in `MindGrapesKit`
(252 tests); UI/CoreLocation/Siri code compiles for the simulator and awaits
HITL.

Foundation and queue core:
- #1 repo/toolchain skeleton
- #2 core models and shared configuration
- #3 wire encoding (note JSON + image multipart)
- #4 `BrainClient` request construction and error mapping
- #5 `CaptureQueue` actor and retry state machine
- #7 Keychain token store
- #11 photo downscale

Slice 1 (submit my first memory): #8 AuthManager, #9 (thin) discovery + healthz,
#10 interactive OAuth, #17 (rough) capture screen, plus the throwaway drain loop.

Slice 2 (photo capture): PhotoSpooler, `CaptureQueue.imageMultipartBody`, the
`CaptureDrainer` photo branch, PhotoDescription template, and the picker/camera
UI. Draws on the image halves of #3/#4 and a sliver of #17.

Slice 3 (location): #14 `LocationProvider` (budgeted one-shot fix + non-fatal
geocode) and the CoreLocation-backed system provider, plus the include-location
toggle.

Slice 4 (real intents): #15 `CaptureIntentRunner` and the CaptureNote /
CapturePhoto / OpenCapture App Intents + `AppShortcutsProvider`, with the capture
screen refactored onto the same runner.

Not started: #6 (Slice 5, background transport), #12 / #13 (Slice 6, OCR + on-
device description), #16 / #18 / #19 / #20 / #21 (Slice 7, real screens +
verification), #23 (app-hosted keychain test).

The offline/queue core, all three capture kinds (note, photo, location), and
every entry point (screen + Siri + Shortcuts) exist and share one pipeline. What
remains is background delivery, on-device photo understanding, the real
onboarding/settings screens, and the device/server verification gate.

---

## Slices

Each slice is independently useful and builds on the one before. Item numbers
refer to the catalog below.

### Slice 1 — Submit my first memory

**Goal.** On the phone: enter the server URL, sign in, type a note, tap Save,
and see it confirmed by a real `experience_id` from the server. The thinnest
real capture. Verify with a row in `brain.experiences` where
`metadata.source = "app"`.

**Reuses, already built:** #2 models (`NoteDraft`, `ServerConfig`,
`CaptureRecord`, shared defaults), #3 note JSON encoding, #4 `BrainClient`
(note send + `/healthz` + error classification), #5 `CaptureQueue` (enqueue,
immediate first attempt, crash recovery come free), #7 Keychain store
(app-side read/write; the read-only extension accessor sits idle).

**Needs:**
- **#9 (thin):** URL normalization + the `/healthz` probe only. No QR.
- **#8 (full core):** DCR, PKCE, code exchange, refresh, `invalid_grant`
  handling. Not shrinkable (see Slice risks). Defer only the extension
  zero-refresh assertion path, since no extension exists yet.
- **#10 (thin):** the `ASWebAuthenticationSession` sheet and callback.
- **New glue, deliberately rough:** a connect/URL screen (one field, a Check
  button showing the `/healthz` result, a Sign in button), a one-field capture
  screen (text field, Save, a line of status text), and a ~50-line foreground
  drain loop (`claimDue` → `BrainClient` → `markSucceeded`/`markFailed`) run
  on save and on app foreground. This is **not** #6; it is throwaway that #6
  replaces wholesale, so keep it dumb.

**Does not need:** #6 background transport, #11–#14 pipeline, #15 formal
intents (call the pipeline from the view for now), #16 onboarding, full #18.

**Server work required, server-side:**
- ✅ Private-use redirect URIs in DCR: server PR #45 is **merged**. OAuth
  sign-in (#10) is unblocked; the loopback bridge is not needed.
- ⏳ **The one remaining blocker: `POST /capture/note`** (SPEC 6.4), tracked as
  `mindgrapes-server` #53. A sibling of `capture_image_api` calling
  `captures.capture(..., client="app")`, reusing the existing field parsers.
  It does not exist yet; `/capture` is extension-only (requires a URL,
  summarizes) so it is no substitute. `effort/S`. Punt the `place_label` open
  question by accepting-and-ignoring or omitting it; Slice 1 sends no location.

Once #53 lands, the client work is unblocked.

**Must-not-forget wiring.** `CaptureQueue` already parks captures in
`authRequired` on `invalid_grant` and revives them via `resumeAfterAuth`. Slice
1's UI must expose a "sign in again" action and call the revival on success, or
the first token expiry strands captures with no way to free them.

### Slice 2 — Photo capture (rough)

**Goal.** Pick or shoot a photo, downscale, upload, confirmed.

**Reuses:** #11 (built), the multipart half of #3/#4.
**Needs:** a camera/picker button, spool-file write to the App Group, and
`imageFilename` on the record. Description is typed or a hardcoded template;
no OCR, no model yet.
**Server gate:** ✅ `POST /capture/image` is **merged** to the server's `main`
(PR #52, attachments images v1). No longer a blocker.
**Maps to:** #11 (done), the remainder of #3/#4, a sliver of #17.

### Slice 3 — Location

**Goal.** Captures carry where they happened.

**Needs:** #14 `LocationProvider` (one-shot fix, 3-second budget, reverse
geocode) plus a toggle in the settings screen and the permission request.
Notes get `lat`/`lng`/`place_label`; images get `lat`/`lng` (the image door has
nowhere to put the label yet, per SPEC 9, and that is fine).
**Maps to:** #14, a sliver of #18.

### Slice 4 — Real intents (Siri and Shortcuts)

**Goal.** "Hey Siri, capture a thought," and every entry point runs the same
code.

**Needs:** #15 intents wrapping the now-proven pipeline; refactor the screens
to invoke them; add `AppShortcutsProvider` (pulled forward from Phase 2 —
near-zero marginal cost once intents exist, and a capability Joe personally
uses). This is where the "every entry point is the same intent" architecture
gets locked in, before more UI accumulates.
**Maps to:** #15 plus a Phase 2 pull-forward.

### Slice 5 — Survives the pocket (background transport)

**Goal.** Airplane-mode capture and kill-mid-upload work for real (success
conditions 4 and 5).

**Needs:** #6 background `URLSession`, spooled bodies, completion
reconciliation, `handleEventsForBackgroundURLSession`, `NWPathMonitor` drain
triggers. Replaces the Slice 1 drain loop. Background-session behavior is
device-verified and fiddly, so it earns its own slice. Also unlocks the share
extension later.
**Maps to:** #6.

### Slice 6 — Smart photos (OCR + on-device description)

**Goal.** A photo of a product label becomes a standalone statement (the
dog-food-label use case).

**Needs:** #12 and #13 behind their protocol seams, the template fallback, and
availability detection. Photos already work end to end from Slice 2; this only
upgrades their content.
**Maps to:** #12, #13.

### Slice 7 — Polish into shippable

**Goal.** The real onboarding, capture, and settings screens, then the Phase 1
gate.

**Needs:** #16 onboarding (QR once the server QR exists; manual entry until
then), #17 capture screen done properly (dictation, focus behavior), #18
settings/queue status (recent captures with sync state, one re-auth prompt,
failed-record export). Then #19–#21 verification and the eight success
conditions.
**Maps to:** #16, #17, #18, #19, #20, #21. #23 app-hosted tests wherever the
Keychain round trip needs real verification.

## Slice risks

- **AuthManager (#8) is not shrinkable.** The server rotates refresh tokens on
  every refresh and treats replay as theft (family revocation, SPEC 5.4). DCR,
  PKCE, exchange, refresh, and rotation handling all have to be right from day
  one, or Slice 1 signs Joe out mysteriously. Keep the single-refresher rule
  from the start even though only one process exists; it costs nothing now and
  retrofitting is exactly what the rule exists to avoid.
- **Every session hits refresh.** The 600-second access TTL means essentially
  every capture session exercises the refresh path. Slice 1 hits it
  immediately, not eventually. That is good: refresh bugs surface fast.
- **Queue parking is already live.** See Slice 1's must-not-forget wiring:
  revival must be wired from the first screen.
- **Conservative retry only.** Server idempotency (`idempotency_key`) is not
  written, so the drain retries only on transport errors and `502` (SPEC 6.3).
  Send the key field anyway; it is ignored harmlessly and turns on aggressive
  retry the day the server honors it.
- **The Slice 1 drain loop is throwaway by design.** Keep it dumb (no
  scheduling cleverness) so Slice 5 replaces it wholesale instead of untangling
  it.
- **SwiftData store tests stay serialized.** Any new queue-adjacent tests in
  Slices 1–2 inherit the `@Suite(.serialized)` rule (SPEC 4.3); concurrent
  `ModelContainer` construction segfaults CoreData.

---

## Item catalog (reference)

The unit of PR work. Slices above draw on these; the acceptance criteria here
are the contract. Items marked **✅ done** are merged to `main`.

### Foundation

#### 1. Repo and toolchain skeleton — ✅ done

`chore` | `loop`

Initialize the repository and the build so everything after this has
somewhere to land.

- `git init`, `.gitignore` for Xcode and SPM, initial commit on `main`.
- Xcode project `MindGrapes` targeting iOS 26, Swift 6 language mode with
  strict concurrency enabled (not minimal, not targeted).
- Local SPM package `MindGrapesKit` with an empty test target, built for iOS
  and watchOS so Phase 3 does not require restructuring.
- App Group `group.net.cotellese.mindgrapes` and a Keychain access group in
  entitlements. Nothing uses them yet; declaring them now avoids a
  provisioning detour mid-feature.
- A `Makefile` or script with `make test` running the package suite, so the
  loop has one command.

Acceptance: `make test` runs and passes with zero tests. `swift build`
succeeds for both iOS and watchOS destinations. Strict concurrency produces
no warnings.

#### 2. Core models and shared configuration — ✅ done

`feat` | `loop`

The types everything else names. SPEC sections 4.1 and 8.1.

- `NoteDraft`, `PhotoDraft`, `ServerConfig`.
- `CaptureRecord` as a SwiftData model with the exact fields in SPEC 8.1,
  including `id: UUID` doubling as the idempotency key, `state`,
  `attemptCount`, `nextAttemptAt`, `lastErrorCode`, `imageFilename`.
- App Group container accessors: SwiftData store URL, photo spool directory,
  shared `UserDefaults` for base URL and the location toggle.
- No behavior beyond construction and persistence.

Acceptance: a `CaptureRecord` round-trips through a SwiftData store created
in a temporary directory. The spool directory resolves inside the App Group
container. Every model is `Sendable` or explicitly documented as not.

#### 3. Wire encoding — ✅ done

`feat` | `loop`

The highest-value loop item: pure functions, exact contract, zero
dependencies. SPEC sections 6.3 and 6.4.

- Multipart builder for `POST /capture/image`: `image` file part plus
  `description`, `ocr_text`, `occurred_at`, `event`, `visibility`, `lat`,
  `lng`, `people`, `labels`, `idempotency_key`.
- JSON encoder for `POST /capture/note`.
- `people` and `labels` use the JSON-array form exclusively, never the
  comma-separated form, because the comma form cannot carry names containing
  commas (SPEC 6.3).
- `lat`/`lng` are both-or-neither, formatted as decimal degrees that survive
  the server's float parse.
- `occurred_at` is always sent as ISO 8601 with a UTC offset, never omitted,
  because client-side downscaling strips the EXIF the server would otherwise
  fall back to.

Acceptance: byte-for-byte assertions on the generated multipart body,
including boundary handling and part ordering. Encoding the same
`CaptureRecord` twice produces an identical `idempotency_key`. A record with
only `lat` set produces neither field. Round-trip a decoded body back through
a parser fixture and confirm every field arrives.

### Transport and queue

#### 4. `BrainClient` request construction and error mapping — ✅ done

`feat` | `loop`

SPEC section 6. No networking behavior yet, only request building and
response interpretation.

- Builds `URLRequest`s for `/healthz`, `/capture/note`, `/capture/image`
  against a configured base URL.
- Decodes the success shapes.
- Maps every documented status to a typed error with a retry classification:
  `400`, `401`, `405`, `413`, `415`, `502`, plus transport errors.
- Takes a `URLSession`, never constructs one.

Acceptance: a `URLProtocol` stub scripts each documented status and the
client produces the right typed error and the right retry classification for
each. Base URLs with and without a trailing slash produce identical request
URLs.

#### 5. `CaptureQueue` — ✅ done

`feat` | `loop`

SPEC sections 8.1, 8.3, 8.5.

- Actor over the SwiftData store. All `CaptureRecord` mutation happens here.
- State machine: `pending`, `inFlight`, `succeeded`, `failed`,
  `authRequired`.
- Backoff: `delay = random(0, min(30 * 2^attempt, 3600))` seconds.
- Crash recovery: the record is durable before the first attempt, and an
  `inFlight` record found at launch returns to `pending`.
- `invalid_grant` parks every pending record in `authRequired` rather than
  failing it; successful re-auth revives them.
- Succeeded records keep `experience_id`, delete their spool file, prune
  after 7 days.
- A late or duplicate failure never resurrects a delivered, terminal, or
  parked record (SPEC 8.2 double-delivery).

Acceptance: state transitions asserted for each error class from item 4.
Backoff bounds asserted across many samples with a seeded generator.
Simulated mid-flight termination leaves a recoverable record. Parked records
are never retried while parked and all revive on re-auth.

#### 6. Background upload transport

`feat` | `loop` for the logic, `device` for the real handoff

Slice 5. SPEC section 8.2. This is the piece that makes an extension capture
reach the server with the app never opened, and it is load-bearing for
Decision 9.

- `URLSessionConfiguration.background(withIdentifier:)` with
  `sharedContainerIdentifier` set to the App Group.
- Bodies written to spool files; `uploadTask(with:fromFile:)` only, since
  background sessions reject in-memory bodies.
- Delegate that reconciles completions against queue records by task
  description, including completions for records this process did not
  submit.
- `application(_:handleEventsForBackgroundURLSession:)` wiring in the app.
- Foreground non-discretionary path for in-app captures so they confirm
  immediately.

Acceptance (`loop`): reconciliation logic tested against synthesized
completion events, including an unknown task id and a completion for a record
already marked succeeded (both must be no-ops, not crashes). Acceptance
(`device`): a capture submitted from a process that then terminates still
completes.

### Authentication

#### 7. Keychain token store — ✅ done

`feat` | `loop`

SPEC section 5.3.

- Stores `client_id`, access token, refresh token, expiry.
- `kSecAttrAccessibleAfterFirstUnlock` so background drains can read while
  locked. `WhenUnlocked` would strand the queue.
- `kSecAttrSynchronizable = false`. A refresh token synced to a second device
  and used from both would trip family revocation.
- Two APIs: a full read/write store for the app, and a **read-only accessor**
  for extensions.

Acceptance: write/read/delete round-trip. The read-only accessor exposes no
mutation and no refresh entry point. Attribute flags asserted on the stored
item.

#### 8. `AuthManager`: DCR, PKCE, refresh

`feat` | `loop`

Slice 1. SPEC sections 5.1, 5.3, 5.4. Everything except the interactive web
sheet.

- Dynamic Client Registration against `/oauth/register`, persisting
  `client_id`.
- PKCE verifier and challenge generation, `S256`.
- Authorization code exchange and refresh against `/oauth/token`.
- Refresh proactively under 60 seconds remaining, otherwise on demand.
- `invalid_grant` transitions to auth-required and never retries blindly.
- **The single-refresher rule**: only the app process refreshes. Extensions
  use the read-only accessor from item 7.

Acceptance: full state machine against a fake clock and a scripted token
endpoint. PKCE challenge verified against the RFC 7636 test vector. The
extension token path issues **zero** calls to the token endpoint however
stale the token is; assert the call count, since this is the property that
prevents the family-revocation sign-out described in SPEC 5.4.

#### 9. Discovery and reachability

`feat` | `loop` plus `server` for the probe

Slice 1 needs the URL-entry + `/healthz` subset; QR is Slice 7. SPEC section
6.1 and Decision 6.

- Manual base URL entry with normalization (scheme defaulting, trailing
  slash, whitespace).
- `/healthz` probe returning a clear reachable / unreachable / wrong-host
  result.
- QR payload parsing and validation.

Acceptance: normalization table asserted over malformed inputs. Probe
behavior asserted against scripted responses including a `200` that is not
`ok`. Against the live dev stack, a correct URL probes reachable and a wrong
one fails within the timeout.

#### 10. Interactive OAuth flow

`feat` | `sim`

Slice 1. SPEC section 5.2.

- `ASWebAuthenticationSession` with
  `Callback.customScheme("net.cotellese.mindgrapes")`.
- URL scheme registered in `Info.plist`.
- Registers `net.cotellese.mindgrapes:/oauth-callback` via DCR.
- Cancel, error, and re-auth paths.

Server dependency: private-use scheme redirect URIs in DCR. ✅ `mindgrapes-server`
PR #45 is **merged**, so this is unblocked and the loopback bridge
(`http://127.0.0.1:<port>/callback`) is not needed.

Acceptance: against the dev stack, a fresh install completes DCR, PKCE, and
consent, and `OAuthClient` shows the registration server-side. Cancelling
mid-sheet leaves no partial state and is retryable.

### Capture pipeline

#### 11. Photo downscale — ✅ done

`feat` | `loop`

SPEC section 7.2 and Decision 4.

- Downscale to 1024px max dimension, matching the server's `MAX_DIM` so the
  server resize is a dimensional no-op.
- Preserve orientation. Never upscale.
- Encode to JPEG under a byte ceiling.

Acceptance: fixture images across orientations, aspect ratios, and formats
(including HEIC) all produce output within bounds with orientation correct.
An image already under 1024px is not upscaled. Output byte length is under
the ceiling for every fixture.

#### 12. OCR seam

`feat` | `loop` for the seam, `sim` for the Vision implementation

Slice 6.

- `TextRecognizing` protocol plus a Vision `RecognizeDocumentsRequest`
  implementation.
- Fake implementation for tests.

Acceptance: pipeline code tested entirely against the fake. The real
implementation is checked against two or three reference images on
simulator, asserting that known strings appear, not exact full output.

#### 13. Description generation and the degraded path

`feat` | `loop` for the seam, `device` for the model

Slice 6. SPEC sections 7.2 and 7.3. The dog-food-label use case: the on-device
model turns OCR plus context into a standalone statement.

- `DescriptionGenerating` protocol plus a Foundation Models implementation
  using `@Generable` guided generation.
- Availability detection for devices without Apple Intelligence.
- Template fallback that composes OCR and metadata into a usable description
  so capture never hard-fails for lack of the model.

Acceptance (`loop`): the template fallback produces a non-empty, sensible
description from OCR alone, and the pipeline selects it whenever the model
reports unavailable. The real model is not unit-tested; it is
nondeterministic. Acceptance (`device`): a photo of a product label produces
a description naming the product.

#### 14. `LocationProvider`

`feat` | `loop` for the logic, `sim` for `CoreLocation`

Slice 3. SPEC section 9.

- One-shot `requestLocation()` at `kCLLocationAccuracyHundredMeters`, When In
  Use only.
- 3-second budget; on timeout the capture proceeds without location.
- `CLGeocoder` reverse geocoding for the label, non-fatal on failure.
- Denied permission turns the toggle off with an explanation and no nagging.

Acceptance: budget enforced against a fake provider that never returns.
Geocode failure yields coordinates without a label rather than dropping
location. Location never delays a capture past the budget, asserted with a
clock.

### Intents and app

#### 15. Capture intents

`feat` | `loop` plus `sim`

Slice 4. SPEC sections 4.1 and 7.1.

- `CaptureNoteIntent`, `CapturePhotoIntent`, `OpenCaptureIntent`.
- Validate, run the pipeline, enqueue, attempt the first upload with a 10
  second budget, return a result phrase.
- The result never depends on the round-trip completing: "Saved." or "Saved,
  will sync."
- Empty content is rejected before enqueue.

Acceptance: `perform()` called directly with injected dependencies asserts
each outcome. An intent with the network down still returns success and
leaves a durable record.

#### 16. Onboarding — ✅ done

`feat` | `sim`

Slice 7. Decision 6 and SPEC 5.1. Shipped as GitHub #20: `ConnectView`
replaces the throwaway `SignInView`, `QRScannerView` reads the code, and
`ServerDiscovery.baseURL(fromScannedCode:)` decides whether a payload is one
of ours. Success condition 1 stays unverifiable until the server renders the
QR (mindgrapes-server#66); manual entry reaches the same state today.

- QR scan of the server base URL, with manual entry as the documented
  fallback.
- `/healthz` probe before proceeding.
- Runs the OAuth flow from item 10.
- Requests location permission with the honest pitch, and sets the toggle.

Acceptance: a fresh install reaches an authenticated, capture-ready state
from a QR scan alone. Manual entry reaches the same state. A bad URL fails
with a clear message and is recoverable without restarting the app.

#### 17. Capture screen

`feat` | `sim`

Slice 1 needs a one-field rough version; the full screen is Slice 7. SPEC
10.1.

- Single screen: text field focused on launch, dictation, camera button,
  photo picker.
- Save invokes the intents from item 15.
- No tab bar, no browse surface.

Acceptance: launch to keyboard-ready with the field focused. Each capture
mode produces a queue record. UI never blocks on the network.

#### 18. Settings and queue status

`feat` | `sim`

Slice 7 for the full screen; Slice 1 needs the URL + sign-in-again subset.

- Server URL, connected status, location toggle, sign out.
- Recent captures with sync state, sourced from the queue.
- Auth-required state surfaced with one re-auth prompt, not a nag per record.
- Failed records stay visible with their error and remain exportable, so no
  capture is silently lost.

Acceptance: revoking the client server-side puts the app in auth-required
state on next drain, queued captures survive, and re-auth drains them.

### Verification

#### 19. Integration suite against the dev stack

`test` | `server`

Slice 7. SPEC 13.2.

- Provision a real bearer token out of band via the server's
  `sign_access_token` management path, which avoids automating passkeys.
- Post a note and an image through `BrainClient` against the live server and
  assert the resulting rows.
- Assert the error contract for real: `413` via an oversize body, `415` via
  garbage bytes, `401` via an expired token.

Acceptance: suite runs green against `make dev-up` and fails loudly if the
wire format drifts.

#### 20. End-to-end

`test` | `sim`

Slice 7. SPEC 13.3.

- XCUITest with a launch argument injecting a minted token and the dev-server
  base URL, bypassing the web sheet.
- Capture text, capture a photo from a fixture, simulate offline at the
  `URLProtocol` layer, verify queue UI states, verify server rows after.

Acceptance: green on simulator, and the offline path demonstrably queues and
drains.

#### 21. Phase 1 success-condition run

`chore` | `device` plus `server`

Slice 7, the gate. Execute the eight success conditions in SPEC section 12
against a real device and a real dev stack, and record the results. Several
cannot be automated honestly: the passkey ceremony, real Apple Intelligence
availability, real background scheduling.

Phase 1 is not done when the code compiles; it is done when these pass:

1. Fresh install onboards via QR, completing DCR, PKCE, and consent.
2. Text capture lands a row with `metadata.source = "app"`, correct
   `occurred_at`, and coordinates when the toggle is on.
3. Photo capture of a document lands an experience whose content is the
   on-device description, with `metadata.ocr` populated, an attachments row,
   a blob under 300 KB, and `vision_status` never `"generated"`.
4. Airplane-mode capture of one note and one photo, then connectivity
   restored: both upload with no user action, exactly one experience each.
5. Kill the app mid-upload, relaunch, the capture completes without
   duplication.
6. With `OAUTH_ACCESS_TTL_SECONDS=60` on the dev server, captures spanning
   several minutes succeed without re-auth and the Keychain holds a rotated
   refresh token.
7. Revoke the app on `/connect/clients`: the next refresh fails, the app
   enters auth-required, queued captures survive, re-auth drains them.
8. On a device without Apple Intelligence, photo capture still succeeds with
   the template description and OCR attached.

### Added after the first five items

#### 23. App-hosted test target for entitlement-gated code

`chore` | `sim`

`SecItem` calls with a Keychain access group return `errSecMissingEntitlement`
(-34018) under `swift test` on macOS **and** under `xcodebuild test` on an
iOS simulator, because an SPM test bundle runs in the generic `xctest`
runner, which carries no `keychain-access-groups` entitlement. Item 7
confirmed this by running it.

Consequence: the real `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate`
/ `SecItemDelete` round trip is unverified. `SystemKeychainTests` exists,
compiles for iOS so it cannot silently rot, and runs only when
`MINDGRAPES_KEYCHAIN_TESTS=1`.

The same gap applies to `AppGroupContainer` from item 2: real App Group
container resolution needs the entitlement too.

- Add a test target hosted by the signed `MindGrapes` app in `project.yml`.
- Wire the gated tests to run there.

Acceptance: the Keychain round trip passes against a real Keychain, and a
regression on `kSecAttrAccessible` fails it rather than only failing the
dictionary assertion.

---

## Server dependencies for Phase 1

From SPEC section 14. Verified against the live `mindgrapes-server` repo on
2026-07-24.

1. **`POST /capture/note`. Not written. The one remaining Slice 1 blocker.**
   Tracked as `mindgrapes-server` #53 (`effort/S`). Text capture cannot reach
   the server until this exists; items 3–5 were built and tested against the
   documented contract, so only the endpoint itself is missing. `/capture`
   exists but is extension-only (requires a URL, summarizes), so it is no
   substitute.
2. ✅ **Private-use scheme redirect URIs in DCR. Merged** (`mindgrapes-server`
   PR #45). #10 / Slice 1 sign-in is unblocked; the loopback bridge is not
   needed.
3. ✅ **`POST /capture/image` is merged to server `main`** (PR #52, attachments
   images v1). Slice 2, item 19, and success condition 3 are no longer gated on
   it.
4. `idempotency_key` on both capture doors. Not written. Not blocking: ship the
   conservative retry set (retry only on network failure and `502`) and send the
   key field anyway; it unlocks aggressive retry when honored.
5. QR on `/connect`. Not written. Not blocking: manual entry is the documented
   fallback (Slice 1 uses it; Slice 7 adds QR).
