# Handoff: Slices 5–6 (background transport, OCR + on-device description)

Built autonomously in one session (agent codename **Bruno**), local commits only
(no pushes, no PRs), each slice adversarially reviewed by two independent agents
before merge. This records what landed, what is loop-verified, and what needs
your hands-on (HITL) check on a simulator and a device.

## What's on local `main`

Merge commits, oldest first:
- `1289016` Slice 5 — background transport (reconciler + reconnect drain)
- `e428d55` Slice 6 — OCR + on-device description

`MindGrapesKit`: **284 tests pass** (`make test`, up from 252). The app **builds
for the simulator** (`make build`), including the real Vision and Foundation
Models paths. Nothing was pushed.

The icon work (`feature/liquid-glass-icon`) and `docs/capture-note-live` are
still separate un-merged branches from the prior session; this session did not
touch them.

## Slice 5 — Background transport (#6)

**The tested core.** `BackgroundUploadReconciler` maps one background-`URLSession`
upload completion onto the `CaptureQueue` (SPEC 8.2). It reuses BrainClient's
status classification (extracted to `BrainClient.error(forStatus:)`) so the
in-process and background paths agree on every documented status. It no-ops on an
unknown/untagged task and on an already-settled record, and — after the review
fold — records a genuine delivery even for a record parked for auth, so a late,
duplicate, or cross-process completion never double-delivers or resurrects a
settled capture. 20 reconciler + queue tests.

**Delivered and wired now (condition 4, app alive):** `MindGrapesAppDelegate`
starts an `NWPathMonitor` (`NetworkPathTrigger`) that drains the outbox through
the existing foreground drainer whenever connectivity is regained. An
airplane-mode capture drains on reconnect **while the app is running**.

**Compile-only device seams (not wired to capture yet):** `BackgroundUploader`
(background session + delegate), request-body spool paths, header-only upload
requests. These exist and compile but nothing routes a capture through them.

### The deferred switchover — condition 5 is NOT delivered

Slice 5's headline goal names conditions 4 **and** 5. Condition 5 (kill the app
mid-upload, it completes on relaunch) needs captures to actually flow through the
background `URLSession`. I deliberately did **not** wire that, because it changes
confirmation semantics and risks double-delivery until the server honors
`idempotency_key`, and it is the fiddly device handoff you asked to be in the
loop for. To finish it (a focused session with you):

1. In the capture path, encode the body, write it to
   `appGroup.requestBodyFileURL(named: id)`, build the header-only request
   (`BrainClient.noteUploadRequest` / `imageUploadRequest`), and call
   `uploader.submit(recordID:request:fromFile:)` instead of (or after a failed)
   foreground drain.
2. Wire `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
   in `MindGrapesAppDelegate` to hand the completion handler to
   `uploader.setBackgroundCompletionHandler`, and call
   `AppComposition.make()` on that relaunch so the session reattaches.
3. Add a `requestBodySpool` sweep to `CaptureQueue.prune` (see the leak note
   below).
4. Decide the double-delivery stance until the server honors `idempotency_key`
   (foreground confirm vs. background durable — do not run both for one record).

### Known edges (Slice 5)

- **Request-body spool leak (latent).** `BackgroundUploader` deletes the spooled
  body only on success/settled; a terminally-failed record's body file is not
  reclaimed (`prune` sweeps only the photo spool). Zero impact today because
  nothing writes those files yet; fix with the sweep in step 3 above when the
  switchover lands.

## Slice 6 — OCR + on-device description (#12, #13)

**The tested core.** `PhotoUnderstanding` composes a photo's `description` and
`ocr_text` with a fixed selection order: a non-blank user description wins, else
the on-device model, else the template fallback. OCR always runs, so `ocr_text`
is populated even when the human worded the description or the model is
unavailable. `PhotoDescription.template` now folds the detected text in (capped
at 240 chars) so a label photo is useful without the model (condition 8);
timestamp-only output is unchanged when there is no OCR. 12 composer/template/
runner tests.

**Durable-first.** After the review fold, `capturePhoto` enqueues the record with
a provisional description **before** the slow OCR + model work, then enriches it
under a budget (`understandingBudget`, default 8s) via
`CaptureQueue.updatePhotoContent`. A kill or a timeout during understanding costs
the smart description, never the capture.

**Real implementations (compile-verified on the simulator, wired into
`AppComposition`):**
- `VisionTextRecognizer` — `VNRecognizeTextRequest`, best-effort (any failure →
  `""`, OCR never fails a capture), with a resume-once guard against Vision's
  double-signal and the OCR moved off the cooperative thread pool.
- `FoundationModelsDescriptionGenerator` — on-device model gated on
  `SystemLanguageModel` availability, OCR fenced as untrusted data in the prompt,
  output capped at 80 tokens. Falls to the template when unavailable.

### HITL checklist (Slice 6)

1. **Simulator OCR.** Capture a photo of a text label; confirm `ocr_text` on the
   image row carries the label's strings (Apple Intelligence is usually off on
   the sim, so the description is the template with the OCR folded in).
2. **Device with Apple Intelligence.** Photo of a product label → the description
   names the product (the dog-food-label case, conditions 3 and 8), `ocr_text`
   populated, `vision_status` never `"generated"`.
3. **Device without Apple Intelligence.** Photo capture still succeeds with the
   template description + `ocr_text` (condition 8).
4. **Latency.** A slow model must not stall the capture: the intent should return
   promptly (the record is durable before understanding runs).
5. Confirm note rows carry **no** `ocr_text` (image-only field).

### Known edges (Slice 6)

- The template's folded OCR is capped at 240 chars for the description; the full
  text still travels in `ocr_text`.
- `FoundationModelsDescriptionGenerator` assumes `respond(to:)` honors task
  cancellation for the budget to abandon promptly; the capture is durable
  regardless.
- Pre-existing `CLGeocoder` deprecation warning (Slice 3, MapKit is the
  replacement) still present; not touched here.

## Review process

Each slice: build the loop-tested core with TDD, then two independent adversarial
reviewers (a Swift/concurrency lens and a logic/contract lens) against the diff,
fold every real finding, re-run the suite, then merge `--no-ff` locally. The
Slice 5 fold caught a real `markSucceeded` resurrection race; the Slice 6 fold
caught a Vision double-resume crash and the durable-first ordering regression.

## Suggested next

- **Finish Slice 5 condition 5** (the switchover above) with you in the loop.
- **Slice 7:** real onboarding/capture/settings screens and the eight-condition
  verification gate (mostly sim/device/server).
