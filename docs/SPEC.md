# MindGrapes iOS: Technical Specification

Founding document for the MindGrapes iOS and watchOS capture client. Server
facts below were verified against `mindgrapes-server` at the time of writing;
file:line citations point at that repo. Where this spec and the server code
disagree, the code wins.

## 1. What this app is, and is not

MindGrapes iOS is a capture surface for the Mind Grapes second brain: the
fastest possible path from "thought" or "thing in front of me" to a durable,
searchable experience row on the self-hosted server. Text in, photos in,
location attached, done in seconds, working offline, from every entry point
iOS offers (app, Siri, Shortcuts, Share Sheet, Control Center, Action Button,
Watch).

It is deliberately not:

- A browsing or reading app. Retrieval is what AI clients over MCP are for.
  A minimal review surface arrives in Phase 4 and stays minimal.
- A photo archive. Photos are visual receipts for traceability; the server
  keeps only a 1024px WebP derivative and discards originals
  (`extraction/images.py:32-35`, docstring at `images.py:3-13`). The app
  matches that: it uploads a downscaled derivative and does not build a local
  library.
- An MCP client. The MCP surface stays for AI clients; this app speaks the
  first-party REST doors (Decision 1 below).
- A notes app with sync, folders, or editing. Capture is append-only; the
  server's supersede/correction pattern handles fixes, and that lives in
  Phase 4 at the earliest.

## 2. Decided items

These are settled. Rationale is recorded so it does not get re-litigated.

1. **Transport: first-party REST, not MCP.** The app posts to the
   bearer-authed HTTP doors in `web/openbrain/core/views.py`. MCP tool
   schemas are LLM-facing and may change wording or shape for LLM reasons;
   the JSON-RPC `initialize` handshake plus session headers is dead weight in
   a short-lived App Intent or Watch extension; `POST /capture/image` already
   exists and its docstring names the app as its client (`core/views.py:253`);
   and MCP returns content blocks rather than typed JSON.

2. **Exactly one new server endpoint: `POST /capture/note`.** A sibling of
   `capture_image_api` with identical auth (`_verify_bearer`, `csrf_exempt`,
   `@cors`). Fields: `content` (required), `occurred_at`, location, `people`,
   `labels`, `visibility`, `idempotency_key`. It calls
   `captures.capture(..., client="app")`. See section 6.4 for the proposed
   wire shape and the location-label question that belongs to the server repo.

3. **Idempotency on both capture doors.** The client generates a UUIDv4 per
   capture and sends it as `idempotency_key` on every attempt, including
   retries. The server upserts on it. Required on `/capture/note` and
   `/capture/image` both, because photo blob dedupe is not request
   idempotency: re-capturing the same photo reuses one blob via
   `ON CONFLICT (bucket, object_key)` but inserts a second attachments row
   (fresh `uuid4`) and a second experience
   (`image_captures.py:59-71, 307-338`; verified). This is what makes the
   offline queue safe to retry aggressively.

4. **Photos are receipts; intelligence runs on device before upload.**
   Vision `RecognizeDocumentsRequest` produces `ocr_text`; the on-device
   Foundation Models framework turns OCR plus context into a standalone
   `description`; the image is downscaled to 1024px max dimension (matching
   the server's `MAX_DIM`, `extraction/images.py:32`) so the server resize is
   a dimensional no-op; `visibility="private"` always, which makes the
   server's third-party vision fallback dead code for this client
   (`image_captures.py:209-227`). Devices without Apple Intelligence degrade
   to OCR-only or user-typed descriptions (section 7.3).

5. **watchOS is standalone.** The Watch app registers its own OAuth client
   via DCR, holds its own tokens in its own keychain, and posts directly over
   WiFi or LTE. It works with the phone absent. WCSession pushes only initial
   configuration (base URL), never captures.

6. **Onboarding via QR code.** The server's `/connect` page
   (`oauth/views.py:172-250`) grows a QR encoding the base URL. Phone scans
   it once, then runs the OAuth flow. Manual URL entry with a `/healthz`
   probe is the documented fallback. mDNS/Bonjour discovery is rejected: the
   server sits behind Tailscale and Docker bridge networking, so "same
   network" is not a meaningful boundary, and Tailscale already solves
   reachability better than mDNS would.

7. **Phase 1 ships auth, text capture, and photo capture** from the app
   itself. Ambient entry points, Watch, and review come later (section 12).

8. **iOS 26+ / watchOS 26+, Swift 6, strict concurrency, SwiftUI, App
   Intents first.** There is no meaningful primary UI; the App Intent is the
   unit of functionality and every entry point, the app UI included, invokes
   the same intent.

9. **Uploads run on a background `URLSession`; only the app refreshes
   tokens.** Extensions enqueue durably and hand the transfer to the system,
   then exit. The transfer completes with the app closed and possibly never
   opened, and the system relaunches the app in the background to reconcile
   the result. Because extensions never call `/oauth/token`, concurrent
   refresh is structurally impossible and the family-revocation sign-out it
   would cause cannot happen. This replaces an earlier design where
   extensions uploaded inline behind a cross-process `flock`: same
   guarantee, one fewer concurrency primitive, and no dependence on the
   user opening the app. Details in sections 5.4 and 8.2, including the two
   real limitations (discretionary scheduling and force-quit).

## 3. Verified server contract, and where the founding brief was wrong

Server: Python 3.12 / Django + FastMCP, Postgres + pgvector, Caddy edge,
reachable over the tailnet plus a public `*.ts.net` Tailscale Funnel URL
(`README.md:82-83`, `docs/deploy.md:144-153`). Single household, passkey
auth. Schema changes are append-only `init/NN-*.sql` files registered in the
`SPINE` in `web/openbrain/mcp/boot.py` and applied with
`manage.py brain_ledger migrate` (server `CLAUDE.md:49-51`).

Discrepancies found during verification (code wins; the spec below reflects
the code):

- **`captures.capture` already has location parameters.** The brief assumed
  the text write path had no location support. It does: `lat` and `lng`
  landed with #43 (`brain/services/captures.py:69-86`). The remaining gap is
  only the place label / accuracy / source metadata, which `capture_image`
  assembles into row metadata itself (`image_captures.py:263-270`) and a note
  endpoint would need to do likewise (or `capture()` grows a `location`
  parameter). That choice belongs to the server repo (section 14).
- **The REST image door drops the place label.** `_location` parses only
  `lat` and `lng` form fields (`core/views.py:209-225`); there is no way to
  pass `label`, `accuracy_m`, or `source` through `POST /capture/image` today
  even though the underlying service supports them. Reverse-geocoded labels
  need a server change (section 14).
- **DCR rejects the standard native-app OAuth callback.**
  `_valid_redirect_uri` accepts https anywhere or http on loopback only, no
  custom schemes (`oauth/views.py:304-326`). An iOS app's private-use scheme
  redirect cannot register. Resolved by decision: the server will accept
  RFC 8252 private-use schemes (section 5.2). Blocking server dependency for
  Phase 1.
- **The REST doors do not consult the revocation watermark.**
  `_verify_bearer` checks signature, `iss`, `aud`, and expiry, nothing else
  (`core/views.py:57-87`). The `(user, client)` revocation watermark
  (`oauth/models.py:220-255`) is enforced by the MCP resource server, not by
  `/capture*`. Practical effect: after revoking the app on
  `/connect/clients`, an already-minted access token keeps working on the
  REST doors for up to the access TTL (600 s default,
  `config/settings/base.py:167`). Filed as a suggested server issue
  (section 14); the app does not depend on it.
- **Scopes exist but are not enforced anywhere the app touches.**
  `oauth/scopes.py` defines `brain:read` and `brain:write` with
  `DEFAULT_SCOPE` granting both, and its own docstring says scope "is a
  product/UX surface, not a security boundary" (`scopes.py:4-7`).
  `_verify_bearer` never reads the `scope` claim. The app requests no scope
  (DCR pins `DEFAULT_SCOPE`, `oauth/views.py:149`) and must not assume scope
  enforcement will ever protect anything.

## 4. Architecture

### 4.1 App-Intent-first layering

Every capture flows through an App Intent. The app UI is a thin invoker of
the same intents that Shortcuts, Siri, Spotlight, Control Center, the Action
Button, widgets, and the Share Sheet use. This is not a style preference: it
is the only way to guarantee that "capture from the car via Siri" and
"capture from the app" are the same tested code path.

Layering, bottom to top:

- `MindGrapesKit` (local Swift package, the shared framework):
  - `BrainClient`: the REST client. Builds requests, encodes the wire
    formats in section 6, maps error codes to typed errors. No UI, no
    storage.
  - `AuthManager` (actor): DCR, PKCE flow driving, token refresh, Keychain
    persistence. Refresh is app-process-only; extensions get a read-only
    token accessor (section 5.4).
  - `CaptureQueue` (actor over a SwiftData store): durable outbox, retry
    scheduling, idempotency keys (section 8).
  - `CapturePipeline`: text normalization; photo downscale, OCR,
    description generation (section 7).
  - `LocationProvider`: one-shot fix plus reverse geocoding (section 9).
  - Models: `NoteDraft`, `PhotoDraft`, `CaptureRecord`, `ServerConfig`.
- App Intents (`CaptureNoteIntent`, `CapturePhotoIntent`,
  `OpenCaptureIntent`): validate parameters, call `CapturePipeline` and
  `CaptureQueue`, return a result phrase. They live in the shared package so
  every target exposes the same intents.
- SwiftUI surfaces: the app's single capture screen, the share extension UI,
  the Watch UI. All call intents (or the same underlying services when an
  intent round-trip adds nothing, e.g. live camera preview).

Compile-time dependency rule: SwiftUI targets depend on intents and
`MindGrapesKit`; intents depend on `MindGrapesKit`; `MindGrapesKit` depends
on nothing app-specific. Networking never appears outside `BrainClient`.

### 4.2 Targets and modules

- `MindGrapes` (iOS app): capture screen, settings, onboarding (QR scan +
  OAuth), queue status view.
- `MindGrapesWidgets` (widget extension): Home Screen / Lock Screen widgets,
  `ControlWidget` for Control Center and the Action Button.
- `MindGrapesShare` (share extension): text/URL/image intake from other
  apps.
- `MindGrapesWatch` (watchOS app): dictation-first capture, its own
  onboarding, its own queue.
- `MindGrapesWatchWidgets` (watchOS widget extension): complication and
  Smart Stack widget.
- `MindGrapesKit` (local SPM package): everything in 4.1, compiled for iOS
  and watchOS.

Shared plumbing:

- One App Group (`group.net.cotellese.mindgrapes`) for the SwiftData store,
  the photo spool directory, the background-session upload bodies, and
  shared `UserDefaults` (base URL, location toggle). The App Group is also
  the background session's `sharedContainerIdentifier` (section 8.2).
- One Keychain access group for tokens, shared by app + extensions on the
  phone. Extensions read; only the app writes (section 5.4). The Watch has
  its own keychain and its own tokens by design (Decision 5).

### 4.3 Concurrency

Swift 6 strict concurrency throughout. `AuthManager` and `CaptureQueue` are
actors; `CaptureRecord` mutation happens only inside `CaptureQueue`.
`BrainClient` is a `Sendable` struct over `URLSession`. Intents are `async`
and never block on the network beyond a short first-attempt budget
(section 8.4).

#### A SwiftData model never crosses an actor boundary

`CaptureRecord` is a `@Model` class: a mutable reference type bound to a
`ModelContext` that is not thread-safe. It is therefore not `Sendable`, and
Swift 6 refuses to let it leave the actor that owns the store. This is a
constraint to design around, not one to suppress with
`@unchecked Sendable`.

The rule: **`CaptureQueue` builds a `Sendable` value snapshot by copying
fields out of the record, and every downstream consumer takes the snapshot
instead of the model.** The wire encoders, `BrainClient`, and the
background-session handoff all sit on the snapshot side of that line.

Why it is worth a second type:

- The encoders become pure functions over values, testable with no SwiftData
  store at all. That keeps them out of the serialized suite that store tests
  require (see below) and out of `ModelContainer` setup entirely.
- The actor stays scoped to storage and state transitions instead of
  absorbing encoding and request construction, which is what happens when
  the model is the only currency.
- Background-session completions arrive outside any actor's isolation
  (section 8.2). A snapshot is something they can legally carry; a model is
  not.
- A model object cannot outlive its context, because nothing downstream ever
  holds one.

Decide this before writing the consumers. Retrofitting it means rewriting
every signature and test that named the model type.

#### Store tests must be serialized

Concurrent `ModelContainer` creation segfaults inside CoreData's schema
setup (`_generateTriggerSQL` mutating a shared dictionary), and Swift
Testing parallelizes by default. Measured at roughly 1 failure in 10 runs
before serializing. Any test that opens a SwiftData store belongs in a
`@Suite(.serialized)`. Pure-value tests need no store and should not create
one; that is another reason the snapshot boundary pays for itself.

## 5. Authentication

### 5.1 The flow

OAuth 2.1 authorization code + PKCE (S256 only, enforced server-side:
`oauth/grants.py:25-32`), public client, no secret. Endpoints, discovered
from RFC 8414 metadata at
`GET /.well-known/oauth-authorization-server` (`oauth/views.py:46-64`,
mounted at the root in `config/urls.py:23-27`):

- `POST /oauth/register`: RFC 7591 Dynamic Client Registration. Open but
  household-constrained: the server ignores requested grant types and pins
  public client, `authorization_code` + `refresh_token`,
  `token_endpoint_auth_method: "none"`, `DEFAULT_SCOPE`, max 5 redirect URIs
  (`oauth/views.py:115-169`). The app self-registers on first launch; no
  operator step, no shipped secret.
- `GET /oauth/authorize`: passkey-gated consent (`@login_required`,
  `oauth/views.py:67-104`).
- `POST /oauth/token`: code exchange and refresh (`oauth/views.py:107-112`).
- `GET /oauth/jwks.json`: the Ed25519 public key (not needed by the app; the
  app never validates tokens, it just presents them).

Client-side sequence on first run:

1. Obtain base URL (QR scan of `/connect`, or manual entry). Probe
   `GET {base}/healthz`, expect `200` with body `ok`
   (`core/views.py:52-54`). Persist as `ServerConfig`.
2. Fetch `/.well-known/oauth-authorization-server`; persist the endpoint
   URLs.
3. `POST /oauth/register` with
   `{"client_name": "MindGrapes iOS", "redirect_uris": [<callback>]}`.
   Persist `client_id` (Keychain, alongside tokens; losing it means
   re-registering, which is harmless but litters the client table).
4. Run `ASWebAuthenticationSession` against `/oauth/authorize` with
   `code_challenge` (S256), `state`, and the registered redirect URI.
   `prefersEphemeralWebBrowserSession = false` so the passkey session cookie
   survives and re-auth is one tap.
5. Exchange the code at `/oauth/token`
   (`grant_type=authorization_code`, `code_verifier`, `client_id`).
   Authorization codes are single-use and expire in 5 minutes
   (`oauth/models.py:126-152`).
6. Persist the token pair; mark onboarding complete.

### 5.2 The redirect URI problem (blocking server dependency)

`_valid_redirect_uri` rejects custom schemes (`oauth/views.py:304-326`), so
the canonical native-app callback (RFC 8252 section 7.1 private-use scheme)
cannot register today. Auth cannot start until this changes, which is why it
is the first server issue in section 14.

**Decided: the server accepts private-use scheme redirect URIs in DCR.**
Small, RFC 8252-sanctioned change, household-scoped like the rest of that
module, and the only option that also works on watchOS (Phase 3). The app
uses a reverse-DNS scheme it owns and
`ASWebAuthenticationSession.Callback.customScheme(...)`:

```swift
// redirect_uri registered via DCR
"net.cotellese.mindgrapes:/oauth-callback"
```

The validator change should keep the existing protections rather than just
adding an escape hatch: no wildcards, no userinfo, ASCII only, no
whitespace, and for the private-use case no authority component (RFC 8252
recommends `scheme:/path`, a single slash). Requiring the scheme to contain
a dot keeps it to reverse-DNS names the app actually controls and preserves
the "a hostile registration can't claim a dangerous callback" property the
current docstring names.

Alternatives considered and rejected:

- **Loopback redirect** (`http://127.0.0.1:<port>/callback`, RFC 8252
  section 7.3) already passes the validator untouched, so it would unblock
  iOS with zero server work. Rejected as the primary path because it means
  running an ephemeral local HTTP listener during auth, and it is not
  viable on watchOS. It remains available as a bridge if iOS work needs to
  start before the server PR lands; the app can register both URIs and
  prefer the private-use scheme when the server accepts it.
- **Claimed https callback** (iOS 17.4+
  `ASWebAuthenticationSession.Callback.https(host:path:)`) passes the
  validator as-is and is genuinely available here, since the deployment has
  a stable public Funnel hostname with a real certificate. Rejected because
  it requires the server to host `apple-app-site-association` and the app to
  carry an Associated Domains entitlement naming a specific host, baked in
  at build time. That couples the binary to one deployment, which a
  self-hostable app should not do, and adds an Apple CDN dependency to the
  login path. (Caddy routing would not have been the obstacle: only
  `/.well-known/oauth-protected-resource*` goes to the MCP service;
  everything else under `/.well-known/` already reaches Django,
  `caddy/Caddyfile:106-121`.)

### 5.3 Tokens: lifetimes, storage, refresh

Server facts (`config/settings/base.py:161-184`, `oauth/models.py`,
`oauth/grants.py:69-97`):

- Access token: EdDSA JWT, default TTL 600 seconds
  (`OAUTH_ACCESS_TTL_SECONDS`). Claims include `sub`, `aud`, `iss`, `iat`,
  `exp`, `scope`, `client_id` (`oauth/jwt.py:64-97`).
- Refresh token: opaque string, single-use, rotates on every refresh
  (`INCLUDE_NEW_REFRESH_TOKEN = True`), no time-based expiry in code.
  Replaying an already-rotated refresh token is treated as theft and revokes
  the entire token family (`oauth/grants.py:74-86`). This drives the design
  in 5.4.

Client behavior:

- Storage: `client_id`, access token, refresh token, and expiry in the
  Keychain, access group shared with the phone extensions,
  `kSecAttrAccessibleAfterFirstUnlock` (background queue drains must read it
  without the device being actively unlocked; `WhenUnlocked` would strand
  the queue), `kSecAttrSynchronizable = false` (tokens must never iCloud-sync;
  the Watch registers separately by design, and a synced refresh token used
  from two devices would trip family revocation).
- Refresh: proactively when the access token has less than 60 seconds left,
  otherwise on demand before an upload. With a 600 s TTL, effectively every
  capture session refreshes; this is fine and exercises rotation constantly.
  Only the containing app ever performs a refresh (section 5.4).
- On `401` from a capture door: force one refresh, retry the request once.
  If refresh itself fails with `invalid_grant`, auth is dead (revoked or
  family-tripped): keep the queue intact, set an "authorization needed"
  state, surface it in the app and in intent results ("Saved locally.
  MindGrapes needs you to sign in again."), and never drop captures.
- Re-auth reuses the stored `client_id`; DCR is not repeated.

### 5.4 Refresh rotation and the single-refresher rule

Rotation plus family revocation makes concurrent refresh from two processes
(app and share extension, say) actively dangerous: process A refreshes,
process B refreshes with the now-rotated token, the server reads that as
replay and kills the family, and the user is signed out. A user who shares
to MindGrapes while the app is foregrounded would be randomly signed out,
with no obvious cause.

The design removes the race rather than guarding it:

- **Exactly one process ever calls `/oauth/token`: the containing app.**
  Extensions and intents running out of process never refresh, so two
  refreshes can never be in flight. There is no cross-process mutex, because
  there is no contended section.
- Extensions read the current access token from the shared Keychain and use
  it as-is, expired or not. With a 600 s TTL they will frequently hold a
  stale one. That is expected and costs one wasted round trip, not a
  failure.
- A `401` on an extension-initiated upload is resolved by the app, not the
  extension. The upload runs on a background `URLSession` (section 8.2), so
  the system delivers its completion to the containing app via
  `application(_:handleEventsForBackgroundURLSession:)`, relaunching the app
  in the background if needed. The app refreshes there and resubmits.
- Consequence: `AuthManager` has no locking, no re-read-after-acquire, and
  no reentrancy concerns. Its refresh path is single-threaded within one
  process and guarded by a plain actor.
- The Watch is a separate OAuth client with its own token family and a
  single process. It refreshes for itself and is structurally outside this
  rule.

The one constraint this places on the Keychain (already in 5.3):
`kSecAttrAccessibleAfterFirstUnlock` plus an App Group access group, so an
extension can *read* the token pair. Extensions never write it.

### 5.5 Watch registration

The Watch runs the same DCR + PKCE flow as its own client
(`client_name: "MindGrapes Watch"`), so revocation on `/connect/clients` is
per-device. WCSession transfers only `ServerConfig` (base URL) so the user
does not type a URL on the Watch; if the phone is absent, manual entry on
the Watch remains possible. Risk: the authorize page is passkey-gated, and
WebAuthn inside a watchOS authentication session is unproven; this is an
open question with fallbacks (section 15), which is part of why the Watch is
Phase 3.

## 6. Server contract

Everything the app touches. Base URL is user-configured (tailnet or Funnel
hostname); all endpoints are relative to it. All capture doors accept
`OPTIONS` preflight and stamp permissive CORS (`oauth/cors.py`), which the
native app ignores.

### 6.1 `GET /healthz`

Plain text `ok`, no auth (`core/views.py:52-54`). Used by onboarding
(URL probe) and by a lightweight reachability check before queue drains.

### 6.2 `POST /capture` (browser extension; the app does NOT use it)

JSON `{url, title, text}`, `url` required; summarizes the page via
OpenRouter and stores `source_kind="imported"`,
`client="browser_extension"` (`core/views.py:118-161`). Not suitable for app
notes: it demands a URL and rewrites content through a summarizer.
Documented here only so nobody wires the app to it.

### 6.3 `POST /capture/image`

The photo door (`core/views.py:250-314`). Bearer-authed, `csrf_exempt`,
`@cors`, multipart form data.

Parts and fields (parsed by `_image_fields`, `core/views.py:228-247`):

- `image` (file part, required): the image bytes. Size checked against
  `settings.MAX_IMAGE_UPLOAD_BYTES` (default 12 MiB,
  `config/settings/base.py:243`) on the upload's `.size` before any bytes
  are read; oversize gets `413`. Content-Type of the part is never trusted;
  the payload is an image only if Pillow decodes it. Accepted formats:
  JPEG, PNG, WebP, GIF, HEIC/HEIF, TIFF, BMP (`extraction/images.py:43`).
- `description` (string): the primary content. Trimmed; empty becomes
  absent.
- `ocr_text` (string): detected text; the server folds it into the embedded
  content as `"\n\nDetected text: ..."` when a description is present
  (`image_captures.py:192-200`).
- `occurred_at` (string): when it happened. Fed to Postgres as
  `::timestamptz`; send ISO 8601 with a UTC offset
  (`2026-07-23T14:03:11-04:00`). Absent falls back to EXIF
  `DateTimeOriginal` server-side, which is moot for this client because
  downscaling strips EXIF; always send it.
- `event` (string): optional event name; server links it as an entity.
- `visibility` (string): `private` or `shared` only
  (`core/views.py:164, 234-236`); default `private`. This client always
  sends `private` (section 11).
- `lat`, `lng` (strings, decimal degrees): both or neither
  (`_location`, `core/views.py:209-225`); must parse as finite floats,
  `lat` in [-90, 90], `lng` in [-180, 180], else `400`. There is NO label /
  accuracy / source field on this door today (section 3).
- `people` (string, `_participants`, `core/views.py:183-206`): either a
  comma-separated name list (`"Anna, Marco"`) or a JSON array whose items
  are strings or objects. Objects pass through verbatim to the resolver, so
  the rich form is `[{"name": "Anna", "relationship": "friend"}]`; an
  object without a usable `name` is silently skipped by the resolver
  (`captures.py:272-275`), so the client must always include `name`. The
  client sends the JSON-array form exclusively; the comma form cannot carry
  names containing commas.
- `labels` (string, `_string_list`, `core/views.py:167-180`): JSON array of
  strings or comma-separated. Lands in row metadata as
  `{"labels": [...]}`. The client sends the JSON-array form exclusively.

Success `200`:

```json
{
  "experience_id": "…uuid…",
  "attachment_id": "…uuid…",
  "object_key": "household/<original_sha256>.webp",
  "byte_len": 43210
}
```

Note `original_sha256` here is the hash of the bytes the client uploaded
(the downscaled JPEG), since the server hashes what it receives
(`extraction/images.py:130-170`); the key shape is
`{account_id}/{sha}.webp` (`blobstore.py:38-40`).

Errors and client behavior:

- `400` (missing `image` part, malformed field): client bug or corrupt
  record. Terminal: mark the queue record failed, keep it visible with the
  error, do not retry.
- `401`: force one token refresh and retry once (section 5.3); if still
  `401`, park the queue in auth-needed state.
- `405`: client bug (wrong method). Terminal.
- `413` (oversize): should be unreachable given client-side downscaling;
  if it occurs, terminal, surfaced as a bug.
- `415` (undecodable image): terminal; the spooled file is corrupt.
- `502` (embedding service down, `core/views.py:302-305`): transient;
  nothing was written server-side. Retry with backoff.
- Network errors / timeouts: retry with backoff.

Retry safety today: a retried request that actually succeeded the first time
creates a duplicate experience (blob dedupe does not dedupe experiences,
section 2 item 3). Until the server ships `idempotency_key`, the client
still sends the field (servers ignore unknown form fields) and retries
conservatively (only on network failure and `502`, where the server states
nothing was written). Aggressive retry unlocks when the server change lands.

### 6.4 `POST /capture/note` (new; server dependency)

The one new endpoint (Decision 2). Sibling of `capture_image_api`: same
`_verify_bearer` auth, `csrf_exempt`, `@cors`. Proposed request, JSON body:

```json
{
  "content": "Met Lung at the LIFT Labs demo; he wants a follow-up.",
  "occurred_at": "2026-07-23T14:03:11-04:00",
  "lat": 39.9526,
  "lng": -75.1652,
  "place_label": "Comcast Center, Philadelphia",
  "people": [{"name": "Lung"}],
  "labels": ["lift-labs"],
  "visibility": "private",
  "idempotency_key": "8B9F6A2E-…"
}
```

`content` required; everything else optional. Calls
`captures.capture(..., client="app")`, which already takes `occurred_at`,
`participants`, `visibility`, `lat`, `lng` (`captures.py:69-86`). Open
server-side decision: where `place_label` lands (a `location` parameter on
`capture()` versus `metadata_extra`, mirroring what `capture_image` does at
`image_captures.py:263-270`). That is the server repo's call, tracked as a
GitHub issue there (section 14); the iOS client isolates the wire shape in
one encoder so it adapts cheaply.

Expected success response: `{"experience_id": "…"}` at minimum. Error
vocabulary should mirror the image door (`400/401/405/502`); the client
treats them identically.

### 6.5 Idempotency semantics (new; server dependency)

`idempotency_key`: client-generated UUIDv4, minted once when the capture
record is created and reused verbatim on every retry. Server upserts: a
second request with the same key returns the original result (same
`experience_id`) and writes nothing. Applies to both doors. Client-side
contract: the key is stored on the `CaptureRecord` before the first network
attempt, so a crash between "server committed" and "client marked done"
resolves to exactly-once on the next retry.

## 7. Capture pipeline

### 7.1 Text

1. Intent receives `content` (typed, dictated, or shared text). Trim;
   reject empty with a spoken/shown error, never enqueue an empty capture.
2. Stamp `occurred_at` (now, ISO 8601 with offset) and the idempotency key.
3. If the location toggle is on, attach the current one-shot fix and
   reverse-geocoded label (section 9). Location acquisition races a 3-second
   budget; on timeout the capture proceeds without location. Location must
   never delay or block a capture.
4. Enqueue; attempt immediate upload (section 8.4); return the intent
   result ("Saved." or "Saved, will sync.").

No LLM touches plain text captures. The user's words are the content, per
the server's design (bare captures get server-side metadata extraction,
`captures.py:141-158`).

### 7.2 Photos

1. Intake: camera capture or library pick (`PhotosPicker`; no library
   permission needed for picking) or Share Sheet image.
2. Downscale on device to 1024 px max dimension (matching server `MAX_DIM`,
   so the server's own LANCZOS resize is dimensionally a no-op and nothing
   is lost that the server would have kept anyway;
   `extraction/images.py:116-127`). Encode JPEG quality ~0.8. iOS has no
   system WebP encoder; the server re-encodes to WebP regardless, so JPEG
   in flight is correct. Result is roughly 150 KB against the 12 MiB
   ceiling. Downscaling strips EXIF (GPS included); safe because the client
   passes location explicitly and `promote_latlng` prefers explicit params
   over EXIF anyway (`extraction/geo.py:49-62`).
3. OCR: Vision `RecognizeDocumentsRequest` on the full-resolution original
   (better OCR than the derivative), producing structured text for
   `ocr_text`. Runs entirely on device.
4. Description: on-device Foundation Models guided generation turns OCR plus
   context (time, place label, user hint if typed) into one clear standalone
   statement for `description`. This satisfies the Mind Grapes contract that
   an experience should make sense when retrieved later by any AI, and it is
   what keeps photo bytes on device (section 11).

```swift
@Generable
struct PhotoStatement {
    @Guide(description: "One or two sentences stating what this photo documents, self-contained, no 'this image shows'")
    var statement: String
}

let session = LanguageModelSession(instructions: describeInstructions)
let response = try await session.respond(
    to: prompt(ocr: ocrText, when: occurredAt, where: placeLabel, hint: userHint),
    generating: PhotoStatement.self
)
```

5. Spool the derivative JPEG to the App Group spool directory; create the
   `CaptureRecord` with all fields and the idempotency key; enqueue.
6. The user can edit the generated description before saving (single
   screen, prefilled). Editing is optional; the default flow is
   two taps: shoot, save.

The server-side vision fallback is intentionally dead code for this client:
it fires only when `visibility == "shared"` AND no description was supplied
(`image_captures.py:209-227`), and this client always supplies a description
(generated, OCR-derived, or typed) and always sends `private`.

### 7.3 Devices without Apple Intelligence

The Foundation Models on-device model requires an Apple-Intelligence-capable
device and the feature enabled. Detect via
`SystemLanguageModel.default.availability`; the `.unavailable` reasons
(`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`) are
distinguished and shown once in settings. Degraded path:

- OCR still runs (Vision has no Apple Intelligence requirement).
- `description` falls back to, in order: user-typed text if present; else a
  deterministic template from context
  (`"Photo captured <date> at <place label>"`) with the OCR carried in
  `ocr_text` as usual.
- `modelReady` is re-checked opportunistically (`modelNotReady` is often
  transient, e.g. model still downloading).

The capture flow never hard-fails for lack of the model.

## 8. Offline queue

### 8.1 Storage

SwiftData store in the App Group container, model `CaptureRecord`:

- `id: UUID` (doubles as `idempotency_key`)
- `kind: .note | .photo`
- note fields / photo metadata fields (content, occurredAt, lat, lng,
  placeLabel, people, labels, description, ocrText, event)
- `imageFilename: String?` (spool file in the App Group, never image bytes
  in the database)
- `state: .pending | .inFlight | .succeeded | .failed | .authRequired`
- `attemptCount: Int`, `nextAttemptAt: Date`, `lastErrorCode: String?`
- `createdAt: Date`

Succeeded records keep `experience_id`, delete their spool file, and are
pruned after 7 days (they back the "recent captures" list in the app).
Failed (terminal) records persist until the user dismisses them; their
payload remains exportable so no capture is ever silently lost.

The phone's queue is shared by app + extensions via the App Group. The
Watch's queue is a separate instance of the same code in the Watch's own
container; the two never merge or relay (Decision 5).

### 8.2 Transport: background `URLSession`

Uploads run on a background session, not an in-process one. This is what
lets a capture made in an extension reach the server with the app never
opened, and it is what makes the single-refresher rule (section 5.4)
workable.

- `URLSessionConfiguration.background(withIdentifier:)` with
  `sharedContainerIdentifier` set to the App Group, so the app and the
  extensions address the same session. The multipart or JSON body is
  written to a spool file in the App Group container and submitted with
  `uploadTask(with:fromFile:)`; background sessions do not accept in-memory
  bodies, which suits the photo path anyway.
- Once the task is handed off, it belongs to the system `nsurlsessiond`
  daemon. The originating process can die immediately (extensions always
  do) and the transfer still completes.
- On completion the system relaunches the containing app in the background
  and calls `application(_:handleEventsForBackgroundURLSession:)`. The app
  reconciles the queue record there: mark succeeded with the returned
  `experience_id`, delete the spool file, or apply the retry rules below.
- The app may additionally run non-discretionary foreground uploads when it
  is active and the user is watching, so an in-app capture confirms
  immediately rather than waiting on the scheduler.

Two limitations, stated rather than papered over:

- **Discretionary scheduling.** Transfers started from an extension are
  treated as discretionary, so the system may hold them for WiFi or power.
  In practice this is minutes, but a cellular-only share capture can lag.
  The record is durable throughout, and the app's own drain (foreground,
  or connectivity restoration) will pick it up sooner if the user opens the
  app.
- **Force-quit.** If the user has force-quit the app from the app switcher,
  iOS will not relaunch it for background session events until they launch
  it once manually. The transfer itself still completes; only the
  completion handling (including the `401` refresh-and-resubmit path) is
  deferred. The queue record is unaffected.

### 8.3 Retry policy

- Retryable: URLSession transport errors, timeouts, `502`.
- Retry-after-refresh: `401`, once per attempt cycle. Handled in the app
  process only (section 5.4), including for extension-initiated uploads.
- Terminal: `400`, `405`, `413`, `415`, and any unexpected 4xx.
- Backoff: exponential with full jitter,
  `delay = random(0, min(30 * 2^attempt, 3600))` seconds; attempt counter
  caps the delay at one hour, never the retries. Queue drains are also
  triggered by connectivity restoration (`NWPathMonitor`), app
  foregrounding, and a `BGProcessingTask` registered for periodic
  background drains. The `BGProcessingTask` is a backstop for records that
  never got a background task submitted (for example, enqueued while the
  device was in a state that refused the handoff), not the primary path.
- Until server-side idempotency lands, the conservative retry set applies
  (section 6.3, last paragraph).

### 8.4 The first attempt

Intents attempt an immediate upload with a short budget (10 s request
timeout) so the common case (online, server up) confirms synchronously.
On failure the record is already durable and a background task carries it;
the intent still returns success ("Saved, will sync") because the capture is
safe. The intent result never depends on the server round-trip having
completed.

### 8.5 Auth expiry while queued

When refresh fails with `invalid_grant`, all pending records move to
`.authRequired` (not `.failed`): they are not retried, not dropped, and the
app surfaces one re-auth prompt. On successful re-auth, `.authRequired`
records revert to `.pending` and drain. Queue contents never gate on token
validity at enqueue time; captures are accepted even while signed out.

## 9. Location

- `CLLocationManager` with When In Use authorization only. No Always, no
  background location, no continuous updates: a capture takes a one-shot
  `requestLocation()` with desired accuracy
  `kCLLocationAccuracyHundredMeters` (a place label does not need better,
  and coarse fixes are fast).
- The "Include location" toggle lives in shared App Group `UserDefaults` so
  app, extensions, and intents agree. Default on, set during onboarding
  when the permission is requested (with the honest pitch: location makes
  memories answer "where was that").
  The Watch keeps its own toggle and uses its own `CLLocationManager`.
- 3-second acquisition budget inside capture (section 7.1). Extensions and
  intents run the same code; if the process cannot get a fix in budget, the
  capture ships without coordinates.
- Reverse geocoding: `CLGeocoder` on the captured fix produces the
  human label (best available of: point of interest name, thoroughfare,
  locality), sent as `place_label` on `/capture/note`. For `/capture/image`
  the label has nowhere to go until the server accepts it (section 3,
  section 14); until then the image door gets `lat`/`lng` only and the
  client keeps the label on the local record so it can be resent later if
  the server grows the field. Geocoding failures are non-fatal; coordinates
  ship without a label.
- If the user denies location permission, the toggle shows as off with an
  explanation; captures proceed without location forever after. No nagging.

## 10. Entry points

Each entry point invokes the same intents (section 4.1).

### 10.1 Main app

Single capture screen: text field focused on launch, mic button
(dictation), camera button, photo picker button. Save invokes
`CaptureNoteIntent` / `CapturePhotoIntent`. Secondary screens: recent
captures with sync state (from the queue), settings (server URL, location
toggle, connected status, sign out), onboarding. There is deliberately no
tab bar and no browse surface.

### 10.2 Home Screen quick actions

`UIApplicationShortcutItem`s: "New note", "Photo capture". Launch into the
capture screen with the respective mode active. Cold-start to
keyboard-ready must be fast enough that quick action → typing feels
immediate; this is a Phase 2 success condition.

### 10.3 Control Center control

A `ControlWidget` (`ControlWidgetButton`) in the widget extension running
`OpenCaptureIntent` with a mode parameter. Text capture needs the keyboard
and therefore opens the app; that is an iOS platform constraint on
controls, not a design choice. The photo control opens the app directly to
the camera.

### 10.4 Action Button

The Action Button can run any App Intent (via the Shortcuts assignment UI)
or a Control. Both paths exist automatically because the intents and the
control exist; the spec adds nothing but documentation in onboarding
("assign MindGrapes capture to your Action Button").

### 10.5 Share Sheet extension

Accepts text, URLs, and images. Text and URLs pre-fill a note draft (URL
captures are still notes: the URL lands in `content`; the app does not call
the browser-extension door, section 6.2). Images run the photo pipeline
(downscale + OCR + description) inside the extension, memory-budget
permitting; the Foundation Models call is skipped in the extension when
under memory pressure and the template fallback applies.

The extension then does exactly two things and exits: write the
`CaptureRecord` and its spool file to the App Group, and hand a background
upload task to the system (section 8.2) using whatever access token is in
the shared Keychain. It does not wait for the response, does not refresh
tokens, and does not require the app to be running or ever opened. If that
token was stale, the resulting `401` is resolved by the app when the system
delivers the completion (section 5.4).

### 10.6 Spotlight and Shortcuts (`AppShortcutsProvider`)

`AppShortcuts` with natural phrases ("Capture a thought with MindGrapes",
"MindGrapes photo") surface in Spotlight, the Shortcuts app, and the Action
Button picker with zero user setup. Parameterized shortcuts let power users
compose (e.g. a Shortcuts automation that captures clipboard contents).

### 10.7 Siri

The same App Shortcuts phrases work by voice, including follow-up dialog
for the note text ("What should I capture?"). The intent runs in the
background without opening the app; the result phrase confirms ("Saved to
your brain"). This is the load-bearing hands-free path, including in the
car (10.9).

### 10.8 watchOS

- App: dictation-first (text field on watchOS is a last resort), one big
  capture button, offline queue status glyph. No photo capture (no
  camera).
- Complication: launches straight into dictation.
- Smart Stack widget: relevance-based (time of day, after workouts;
  tune later) with a capture button.
- Own OAuth client, own tokens, own queue (Decisions 5; risks in
  section 15).

### 10.9 CarPlay: the reality check

CarPlay was on the original wish list. It does not survive contact with
Apple's entitlement policy, and this spec will not pretend otherwise.

- CarPlay app templates require the CarPlay app entitlement, granted
  per-category. As of current Apple documentation the categories are:
  navigation, audio, communication (messaging/VoIP), EV charging, parking,
  quick food ordering, driving task, plus automaker apps. A note-capture
  app fits none of them; "driving task" is scoped to tasks about the drive
  itself (tolls, mileage logs, road-side assistance style apps), and
  Apple's guidance explicitly warns the category is not a catch-all.
  A CarPlay entitlement application for this app should be expected to be
  denied.
- What is actually achievable in the car, today, with no entitlement:
  Siri + App Intents through the phone. "Hey Siri, capture a thought" works
  over the car's microphone and speakers while CarPlay is active, because
  the intent runs on the phone. A Shortcuts personal automation ("When
  connected to CarPlay") can additionally surface a suggested capture
  action or speak a reminder.
- Consequence: the honest car story is 10.7 done well: robust dialog,
  fast confirmation, zero screen dependence. That is what gets built, in
  Phase 2. No CarPlay template target, no `CPTemplateApplicationScene`,
  ever, unless Apple's categories change; if they do, that is a new spec
  discussion, not a silent addition.

## 11. Privacy

What leaves the device, exhaustively:

- Capture payloads (text content, photo derivative, OCR text, generated
  description, coordinates and place label, people names, labels,
  timestamps) go to the user's own server over TLS, bearer-authed. Nothing
  goes anywhere else. There is no analytics SDK, no crash reporter that
  ships content, no third-party endpoint in the app.
- Photo bytes and third parties: the server's vision fallback egresses
  image bytes to OpenRouter only when `visibility == "shared"` and no
  description was supplied (`image_captures.py:209-227`). This client
  always supplies a description and always sends `visibility="private"`,
  so no photo captured by this app ever reaches a third-party vision
  model. Private-by-default is not just a data-access setting on the
  server (viewer filtering, `init/12`, `init/13`); it is the switch that
  keeps this client's bytes on the household's infrastructure.
  Server-side, text content of captures does flow through OpenRouter for
  embedding and (bare captures) metadata extraction; that is the server's
  documented design, noted here for honesty, not something the client can
  or should toggle.
- On-device intelligence (OCR, Foundation Models description) runs
  entirely on device by construction.

Info.plist usage descriptions (exact strings to ship, subject to copy
editing):

- `NSCameraUsageDescription`: "MindGrapes uses the camera to capture photo
  memories."
- `NSLocationWhenInUseUsageDescription`: "MindGrapes attaches your current
  location to captures so your memories can answer where things happened.
  Optional; controlled by the Include Location setting."
- `NSMicrophoneUsageDescription` / speech recognition entries only if
  in-app dictation uses `SFSpeechRecognizer` rather than the system
  keyboard's dictation; the keyboard path needs no entry and is the
  default plan.
- No photo library usage description needed for `PhotosPicker` (picker
  runs out of process).

## 12. Phases

### Phase 1: auth + text + photo from the app

- Goal: a phone can be onboarded to a Mind Grapes server and reliably
  capture text and photos from the app, offline included.
- Scope: `MindGrapesKit` (client, auth, queue, pipeline), onboarding
  (QR + manual URL), OAuth flow, capture screen, camera/picker photo flow
  with OCR + on-device description + degraded path, the two intents
  existing and used by the app UI, queue with retry.
- Out of scope: share extension, widgets/controls, Siri phrases and
  Spotlight exposure (`AppShortcutsProvider` ships in Phase 2 even though
  the intents exist), Watch, any read/browse surface.
- Server dependencies: `POST /capture/note`; `idempotency_key` on both
  doors; DCR redirect-URI change (blocking for auth); QR on `/connect`
  (non-blocking; manual entry is the fallback). Optionally the image-door
  place-label field.
- Success conditions (each independently checkable):
  1. Fresh install against a dev-stack server (`make dev-up`): onboarding
     via QR completes DCR + PKCE + consent, and `OAuthClient` shows the
     app's registration server-side.
  2. Text capture from the app lands a row in `brain.experiences` with
     `metadata.source = "app"`, correct `occurred_at`, and (toggle on)
     `lat`/`lng` populated; verified by querying the dev Postgres.
  3. Photo capture of a document lands an experience whose content is the
     on-device description, `metadata.ocr` populated, an attachments row,
     and a blob whose `byte_len` is under 300 KB; `vision_status` is
     `"skipped_private"` or absent, never `"generated"`.
  4. Airplane-mode capture (one note, one photo), then connectivity
     restored: both upload without user action, and exactly one experience
     each exists server-side (count by content; with server idempotency
     landed, count by idempotency key).
  5. Kill the app mid-upload; relaunch; the capture completes without
     duplication.
  6. Token refresh: with `OAUTH_ACCESS_TTL_SECONDS=60` on the dev server,
     captures spanning several minutes succeed without re-auth, and the
     Keychain holds a rotated refresh token.
  7. Revoke the app on `/connect/clients`: the next refresh fails, the app
     enters auth-required state, queued captures survive, and re-auth
     drains them.
  8. On a non-Apple-Intelligence simulator/device profile, photo capture
     still succeeds with the template description and OCR attached.

### Phase 2: ambient entry points

- Goal: capture without opening the app; the intent surface becomes the
  product.
- Scope: `AppShortcutsProvider` (Siri + Spotlight + Shortcuts), Share
  Sheet extension, Control Center control, Action Button documentation,
  Home Screen quick actions, Lock Screen / Home Screen widget with a
  capture button, and the extension-to-background-session handoff
  (section 8.2) exercised for real.
- Out of scope: Watch, read surface, CarPlay template (permanently,
  section 10.9).
- Server dependencies: none beyond Phase 1.
- Success conditions:
  1. "Hey Siri, capture a thought with MindGrapes" completes a capture
     with the app closed (backgrounded and cold), confirmed by a server
     row.
  2. Sharing a page from Safari and a photo from Photos each produce
     correct captures; the photo path produces an on-device description
     (or template under memory pressure) and never blocks the host app
     beyond the sheet's dismissal.
  3. Control Center photo control reaches a ready camera; measured
     cold-start budget: control tap to shutter-ready in under 2 s on the
     oldest supported hardware.
  4. Share a capture with the app **never launched since install**, then do
     not touch the app: the capture reaches the server on its own. Verified
     by a server row with no app foreground event in between.
  5. Share a capture while the stored access token is already expired: the
     upload `401`s, the system relaunches the app in the background, the app
     refreshes once and resubmits, and exactly one experience exists
     server-side. The token family is not revoked and the user is not
     signed out. Repeatable via a scripted harness with
     `OAUTH_ACCESS_TTL_SECONDS` lowered on the dev server.
  6. Every entry point produces rows indistinguishable (fields, metadata)
     from app-UI captures, verified by a diff of server rows.

### Phase 3: watchOS standalone

- Goal: capture from the wrist with the phone left at home.
- Scope: Watch app (dictation capture), own DCR/OAuth (pending the
  feasibility answer in section 15), own queue, complication, Smart Stack
  widget, WCSession config push.
- Out of scope: photos on Watch, browsing on Watch.
- Server dependencies: possibly an alternative auth path if
  WebAuthn-in-watch-session proves infeasible (section 15); otherwise
  none.
- Success conditions:
  1. Watch with WiFi, paired phone powered off: dictated capture lands
     server-side.
  2. Watch offline: capture queues; lands after connectivity returns;
     exactly once.
  3. `/connect/clients` shows phone and Watch as separate clients;
     revoking the Watch does not sign out the phone.
  4. Complication tap to dictation-ready in under 2 s.

### Phase 4: review and manage

- Goal: see what you captured recently, fix mistakes, from the phone.
- Scope: recent-captures list backed by server reads (not just the local
  queue), experience detail with attachment thumbnail (presigned GET),
  supersede/correct flows using the server's correction pattern, search.
- Out of scope: full browsing/graph UI, entity management, anything the
  MCP clients already do better.
- Server dependencies: the largest of any phase, and the reason this
  phase floats: REST read doors do not exist. The MCP layer has
  `search_thoughts`, `list_thoughts`, `get_experience`, and the
  supersede/correction tools, but the REST surface has only capture
  doors. Needed: bearer-authed REST reads (list/search/get, presigned
  attachment URL via `blobstore.presign`, `blobstore.py:160-169`) and a
  REST supersede/correct door. Scoped as server issues (section 14) and
  re-specced when those land; the app-side details here are intentionally
  thin until then.
- Success conditions (provisional): recent list matches server truth;
  attachment thumbnails render via short-TTL presigned URLs that are
  never persisted or logged; a correction produces a `correction_events`
  row and the superseded experience stops surfacing in default reads.

## 13. Testing strategy

Per the standing policy: unit, integration, and end-to-end, all three, for
shipping application code.

### 13.1 Unit (fast, no network, every PR)

`MindGrapesKit` is designed to be tested here:

- Wire encoding: multipart builder byte-for-byte (field names, JSON-array
  `people`/`labels` forms, lat/lng formatting, both-or-neither location),
  note JSON encoding, idempotency key stability across retries.
- Auth state machine: refresh-when-stale, 401-refresh-retry-once,
  invalid_grant to auth-required, all against a fake clock and a scripted
  token endpoint. Also that the read-only token accessor used by extensions
  never issues a refresh, however stale the token is (section 5.4): assert
  zero calls to the token endpoint from that path.
- Queue: backoff computation, state transitions, terminal vs retryable
  error mapping, crash-recovery (record persisted before first attempt),
  auth-required parking and revival, and reconciliation of a completion
  arriving for a record the current process did not submit (the
  extension-handoff case, section 8.2).
- Pipeline: downscale invariants (max dim 1024, orientation preserved,
  output under a byte ceiling for reference images), template description
  fallback, OCR and description generation behind protocol seams
  (`TextRecognizing`, `DescriptionGenerating`) with fakes; the real
  Foundation Models call is not unit-tested (nondeterministic model), its
  integration is covered manually and by the degraded-path tests.
- Network faking: a `URLProtocol` stub registered on the `URLSession`
  configuration, asserting raw request bytes and scripting responses.
  `BrainClient` takes a session, never creates one.

### 13.2 Integration (against the real dev server)

The server repo's dev stack (`make dev-up`) is the fixture. Two facts make
this automatable without solving passkey automation:

- `sign_access_token` mints valid tokens directly via management command
  (`oauth/jwt.py:64-70` docstring), so tests provision a real bearer token
  out of band.
- `/healthz`, DCR, `/oauth/token` refresh, and the capture doors are all
  plain HTTP.

Suite (runs on a Mac with the dev stack up; CI-optional, required before
release):

- DCR round-trip; PKCE code exchange using a scripted session cookie is
  out of scope (passkey), but refresh-token rotation and family-revocation
  behavior are exercised with minted tokens plus direct `OAuthToken` state.
- Capture doors: post a note and an image through `BrainClient` against
  the live server, then assert rows via a test-only query helper (or the
  server's integration harness). Asserts the full contract of section 6
  including error statuses (413 via oversize body, 415 via garbage bytes,
  401 via expired token).
- Idempotency (once server-side lands): same key twice, one experience.

### 13.3 End-to-end

- XCUITest on simulator, app configured with a test-only launch argument
  that injects a minted token and the dev-server base URL (bypassing the
  web auth UI): capture text, capture photo from a fixture image, toggle
  airplane mode via network-condition injection at the `URLProtocol`
  layer, verify queue UI states, verify server rows afterward via the
  integration helper.
- App Intents: invoked directly in tests (`perform()` with injected
  dependencies), plus an XCUITest driving Shortcuts-surface invocation on
  simulator where supported.
- Watch: shared-package unit suite runs on the watchOS simulator
  destination; XCUITest covers the Watch capture flow on the paired
  simulator pair.
- The interactive OAuth ceremony (ASWebAuthenticationSession + passkey +
  consent) cannot be honestly automated; it is a written manual test
  script executed per release and after any auth change. Everything below
  the web sheet (code exchange, refresh, rotation, revocation) is
  automated in 13.2.

Test output pristine, per house rules; expected-failure paths assert their
logs.

## 14. Server dependency summary

Each phrased as a GitHub issue title for `mindgrapes-server` (its CLAUDE.md
says GitHub Issues is where the roadmap lives). Blocking flags are for
Phase 1 unless noted.

1. `Accept RFC 8252 private-use scheme redirect URIs in Dynamic Client
   Registration` (blocking: the iOS OAuth callback cannot register today;
   `oauth/views.py:304-326`). Decided, section 5.2. Loosen
   `_valid_redirect_uri` to allow a private-use scheme containing a dot
   (reverse-DNS, app-controlled) with no authority component, keeping the
   existing wildcard / userinfo / non-ASCII / whitespace rejections intact.
   Unit tests in `openbrain/oauth/tests/unit/` covering both the accepted
   shape and each rejection that must survive.
2. `Add POST /capture/note: bearer-authed JSON text-capture door for the
   app` (blocking; includes deciding where place_label lands relative to
   captures.capture, which already has lat/lng).
3. `Add idempotency_key upsert to /capture/note and /capture/image`
   (blocking for aggressive offline retry; Phase 1 ships with
   conservative retry if this lags).
4. `Render a QR code of the server base URL on /connect` (non-blocking;
   manual URL entry is the fallback).
5. `Accept place label (and accuracy/source) fields on POST /capture/image`
   (non-blocking; image captures ship lat/lng-only until then).
6. `REST doors should honor the (user, client) revocation watermark like
   the MCP resource server does` (non-blocking hygiene; found during
   verification, section 3).
7. Phase 4, to be scoped when Phase 4 starts:
   `REST read doors for the app: list/search/get experience with presigned
   attachment URLs` and
   `REST supersede/correction door for the app`.
8. Phase 3, contingent (section 15):
   `Alternative device authorization path for watchOS if WebAuthn cannot
   complete in a watch authentication session`.

## 15. Open questions

Genuinely open; nothing here re-opens section 2.

1. **watchOS auth feasibility.** Can the passkey ceremony behind
   `/oauth/authorize` complete inside a watchOS
   `ASWebAuthenticationSession`? Unproven. If not, options are (a) a
   device-authorization-style grant on the server (RFC 8628 flavor:
   Watch shows a code, user approves on the phone or any browser), or
   (b) phone-brokered enrollment where the phone completes the flow for
   the Watch's own client_id and hands the token pair over WCSession
   once (keeps per-device revocation, bends "Watch does its own flow").
   Must be answered by a spike before Phase 3 is planned in detail.
2. **`place_label` landing zone on the note path.** Server repo's call:
   `location` parameter on `captures.capture` versus `metadata_extra`
   (issue 2 in section 14). The client encoder adapts to either.
3. **Camera captures and the Photos library.** Current stance: camera
   shots exist only in the upload spool and are deleted after sync (the
   receipt lives on the server). Is a "also save to Photos" toggle
   wanted? Cheap either way; needs a product decision, not a technical
   one.
4. **Reverse-geocode label granularity.** POI name vs street vs
   neighborhood; and whether the label should be user-editable at capture
   time. Currently: best-available automatic, not editable.
5. **Queue retention numbers.** 7-day retention for succeeded records and
   the 1-hour backoff cap are defensible defaults, not measured ones;
   revisit after real usage.
6. **Smart Stack relevance tuning** (Phase 3): which signals actually
   predict capture moments.
7. **Whether `/capture/note` should also accept `event`** like the image
   door does (`core/views.py:242`); cheap to include server-side, omitted
   from the proposed shape until the server issue discussion settles it.
