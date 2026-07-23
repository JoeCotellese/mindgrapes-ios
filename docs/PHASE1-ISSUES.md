# MindGrapes iOS: Phase 1 work breakdown

Companion to `SPEC.md`. Phase 1 is defined in SPEC section 12: a phone can be
onboarded to a Mind Grapes server and reliably capture text and photos from
the app, offline included.

Every item below is sized to be one branch and one PR. Each carries an
explicit verification mode, because that determines what can be built in an
automated loop and what needs a human, a device, or a running server.

## Verification modes

- **`loop`**: verifiable by `swift test` on the `MindGrapesKit` package. No
  simulator, no server, no device, no network. These can be built
  unattended against a failing test.
- **`sim`**: needs an iOS simulator (UI, system frameworks, XCUITest).
- **`device`**: needs real hardware (camera, Apple Intelligence, background
  session behavior under real scheduling).
- **`server`**: needs the dev stack up (`make dev-up` in the server repo),
  and in some cases a server PR merged first.

## Dependency shape

- Items 1 through 3 are the foundation. Nothing else starts first.
- Items 4 through 8 and 11 through 13 are the `loop` core. This is the bulk
  of the real logic and it can all be built before the server PRs land.
- Item 10 is the only Phase 1 item hard-blocked on a server merge.
- Items 14 through 18 assemble the shippable app.
- Items 19 through 21 verify it.

Rough critical path: 1, 2, 3, 6, 8, 10, 16, 18, 21.

---

## Foundation

### 1. Repo and toolchain skeleton

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

### 2. Core models and shared configuration

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

### 3. Wire encoding

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

---

## Transport and queue

### 4. `BrainClient` request construction and error mapping

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

### 5. `CaptureQueue`

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

Acceptance: state transitions asserted for each error class from item 4.
Backoff bounds asserted across many samples with a seeded generator.
Simulated mid-flight termination leaves a recoverable record. Parked records
are never retried while parked and all revive on re-auth.

### 6. Background upload transport

`feat` | `loop` for the logic, `device` for the real handoff

SPEC section 8.2. This is the piece that makes an extension capture reach the
server with the app never opened, and it is load-bearing for Decision 9.

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

---

## Authentication

### 7. Keychain token store

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

### 8. `AuthManager`: DCR, PKCE, refresh

`feat` | `loop`

SPEC sections 5.1, 5.3, 5.4. Everything except the interactive web sheet.

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

### 9. Discovery and reachability

`feat` | `loop` plus `server` for the probe

SPEC section 6.1 and Decision 6.

- Manual base URL entry with normalization (scheme defaulting, trailing
  slash, whitespace).
- `/healthz` probe returning a clear reachable / unreachable / wrong-host
  result.
- QR payload parsing and validation.

Acceptance: normalization table asserted over malformed inputs. Probe
behavior asserted against scripted responses including a `200` that is not
`ok`. Against the live dev stack, a correct URL probes reachable and a wrong
one fails within the timeout.

### 10. Interactive OAuth flow

`feat` | `sim` | **blocked on server PR**

SPEC section 5.2. This is the only Phase 1 item hard-blocked on a merge.

- `ASWebAuthenticationSession` with
  `Callback.customScheme("net.cotellese.mindgrapes")`.
- URL scheme registered in `Info.plist`.
- Registers `net.cotellese.mindgrapes:/oauth-callback` via DCR.
- Cancel, error, and re-auth paths.

Blocked on: server issue `Accept RFC 8252 private-use scheme redirect URIs in
Dynamic Client Registration`. Until it merges, the loopback redirect
(`http://127.0.0.1:<port>/callback`) already passes the server's validator
and can serve as a bridge, at the cost of an ephemeral local listener. Do not
build the bridge unless the merge actually lags; it is throwaway code.

Acceptance: against the dev stack, a fresh install completes DCR, PKCE, and
consent, and `OAuthClient` shows the registration server-side. Cancelling
mid-sheet leaves no partial state and is retryable.

---

## Capture pipeline

### 11. Photo downscale

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

### 12. OCR seam

`feat` | `loop` for the seam, `sim` for the Vision implementation

- `TextRecognizing` protocol plus a Vision `RecognizeDocumentsRequest`
  implementation.
- Fake implementation for tests.

Acceptance: pipeline code tested entirely against the fake. The real
implementation is checked against two or three reference images on
simulator, asserting that known strings appear, not exact full output.

### 13. Description generation and the degraded path

`feat` | `loop` for the seam, `device` for the model

SPEC sections 7.2 and 7.3. This is the dog-food-label use case: the on-device
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

### 14. `LocationProvider`

`feat` | `loop` for the logic, `sim` for `CoreLocation`

SPEC section 9.

- One-shot `requestLocation()` at `kCLLocationAccuracyHundredMeters`, When In
  Use only.
- 3-second budget; on timeout the capture proceeds without location.
- `CLGeocoder` reverse geocoding for the label, non-fatal on failure.
- Denied permission turns the toggle off with an explanation and no nagging.

Acceptance: budget enforced against a fake provider that never returns.
Geocode failure yields coordinates without a label rather than dropping
location. Location never delays a capture past the budget, asserted with a
clock.

---

## Intents and app

### 15. Capture intents

`feat` | `loop` plus `sim`

SPEC sections 4.1 and 7.1.

- `CaptureNoteIntent`, `CapturePhotoIntent`, `OpenCaptureIntent`.
- Validate, run the pipeline, enqueue, attempt the first upload with a 10
  second budget, return a result phrase.
- The result never depends on the round-trip completing: "Saved." or "Saved,
  will sync."
- Empty content is rejected before enqueue.

Acceptance: `perform()` called directly with injected dependencies asserts
each outcome. An intent with the network down still returns success and
leaves a durable record.

### 16. Onboarding

`feat` | `sim`

Decision 6 and SPEC 5.1.

- QR scan of the server base URL, with manual entry as the documented
  fallback.
- `/healthz` probe before proceeding.
- Runs the OAuth flow from item 10.
- Requests location permission with the honest pitch, and sets the toggle.

Acceptance: a fresh install reaches an authenticated, capture-ready state
from a QR scan alone. Manual entry reaches the same state. A bad URL fails
with a clear message and is recoverable without restarting the app.

### 17. Capture screen

`feat` | `sim`

SPEC 10.1.

- Single screen: text field focused on launch, dictation, camera button,
  photo picker.
- Save invokes the intents from item 15.
- No tab bar, no browse surface.

Acceptance: launch to keyboard-ready with the field focused. Each capture
mode produces a queue record. UI never blocks on the network.

### 18. Settings and queue status

`feat` | `sim`

- Server URL, connected status, location toggle, sign out.
- Recent captures with sync state, sourced from the queue.
- Auth-required state surfaced with one re-auth prompt, not a nag per record.
- Failed records stay visible with their error and remain exportable, so no
  capture is silently lost.

Acceptance: revoking the client server-side puts the app in auth-required
state on next drain, queued captures survive, and re-auth drains them.

---

## Verification

### 19. Integration suite against the dev stack

`test` | `server`

SPEC 13.2.

- Provision a real bearer token out of band via the server's
  `sign_access_token` management path, which avoids automating passkeys.
- Post a note and an image through `BrainClient` against the live server and
  assert the resulting rows.
- Assert the error contract for real: `413` via an oversize body, `415` via
  garbage bytes, `401` via an expired token.

Acceptance: suite runs green against `make dev-up` and fails loudly if the
wire format drifts.

### 20. End-to-end

`test` | `sim`

SPEC 13.3.

- XCUITest with a launch argument injecting a minted token and the dev-server
  base URL, bypassing the web sheet.
- Capture text, capture a photo from a fixture, simulate offline at the
  `URLProtocol` layer, verify queue UI states, verify server rows after.

Acceptance: green on simulator, and the offline path demonstrably queues and
drains.

### 21. Phase 1 success-condition run

`chore` | `device` plus `server`

Execute the eight success conditions in SPEC section 12 against a real device
and a real dev stack, and record the results. Several cannot be automated
honestly: the passkey ceremony, real Apple Intelligence availability, real
background scheduling.

This is the gate. Phase 1 is not done when the code compiles; it is done when
these pass:

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

---

## What can be looped

Items 2 through 9, 11, and 13 through 15 are `loop`-verifiable, which is most
of the actual logic: encoding, error mapping, the queue state machine,
backoff, the auth state machine, downscaling, the degraded description path,
and intent behavior. That is a large unattended run with `swift test` as the
signal, and none of it waits on a server merge.

What cannot be looped, and should not be attempted unattended: item 10 (the
interactive OAuth sheet), the real Vision and Foundation Models
implementations in items 12 and 13, everything in the app and onboarding
group, and all of item 21.

## Server dependencies for Phase 1

From SPEC section 14:

1. Private-use scheme redirect URIs in DCR. **Blocks item 10.** Decided,
   PR in flight.
2. `POST /capture/note`. Blocks text capture reaching the server, though
   items 3 through 5 can be built and tested against the documented contract
   before it lands.
3. `idempotency_key` on both capture doors. Not blocking: Phase 1 ships with
   the conservative retry set (retry only on network failure and `502`) if
   this lags, and unlocks aggressive retry when it merges.
4. QR on `/connect`. Not blocking: manual entry is the documented fallback.
