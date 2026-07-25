# Autonomous plan: Slices 5 and 6

Session goal: build Slice 5 (background transport, #6) and Slice 6 (OCR +
on-device description, #12/#13). Local commits only, no pushes/PRs. Adversarial
review after each slice. Simulator/device verification is Mr. Cotellese's HITL
step at the end.

Codename for this run's agent: **Bruno**.

## Ground rules

- Branch per slice off local `main`; merge locally with `--no-ff`.
- TDD in `MindGrapesKit` for every loop-verifiable piece (`make test`).
- Success condition each slice must hold before merge: `make test` green +
  `make build` green (simulator compile).
- After each slice: spawn independent adversarial reviewers, fold findings,
  re-run tests, then merge.
- Honest reporting: device/sim-only behavior gets marked NOT VERIFIED in the
  handoff doc, never claimed working.

## Slice 5 — Survives the pocket (background transport, #6)

What is loop-verifiable (build + test here, no device):
- `BackgroundUploader` seam over `URLSessionConfiguration.background(...)` with
  `sharedContainerIdentifier` = App Group. `uploadTask(with:fromFile:)` only.
- Task identity: tag each upload task with the `CaptureRecord.id` (task
  description) so a completion maps back to a record — including completions for
  a record this process did not submit.
- **Reconciliation logic** (the testable core, SPEC 8.2): given a synthesized
  completion (task id + HTTP status/error + response body), resolve it to
  `markSucceeded` / `markFailed` / no-op. Must no-op on:
  - unknown task id,
  - a record already terminal (succeeded/failed/unsendable),
  - a duplicate completion for an already-succeeded record.
- Body spooling: note/image bodies written to files under the App Group so a
  background task can read them after the process dies.
- `NWPathMonitor` drain trigger seam (become-satisfied → kick a drain).

What is device-only (HITL, marked NOT VERIFIED):
- `application(_:handleEventsForBackgroundURLSession:)` wiring + real handoff.
- Foreground non-discretionary path confirming immediately.
- A capture submitted from a process that then terminates still completing.

Design intent: the reconciler is a pure-ish function/actor method tested against
synthesized events. The real `URLSession` background delegate is a thin adapter
that calls the reconciler. `CaptureDrainer` stays for the foreground/immediate
path; the background session is the durable path. Do not delete the drainer
until the app wiring proves the replacement on device (Slice 7 / HITL).

## Slice 6 — Smart photos (OCR + on-device description, #12/#13)

Loop-verifiable:
- `TextRecognizing` protocol (#12) + a fake; Vision `RecognizeDocumentsRequest`
  impl compiled but exercised on sim (HITL).
- `DescriptionGenerating` protocol (#13) + a fake; Foundation Models impl
  compiled but not unit-tested (nondeterministic, device HITL).
- Availability detection: when the model reports unavailable, the pipeline
  selects the **template fallback**. Test that selection deterministically.
- Template fallback upgraded to compose OCR text + metadata into a non-empty,
  sensible description (today it is timestamp-only in `PhotoDescription`).
- Wire the photo capture path to: OCR → description (model or fallback) →
  `ocr_text` + `description` on the record. `ocr_text` populated even when the
  model is unavailable.

Device-only (HITL):
- Real Vision OCR on reference images.
- Real Foundation Models description naming a product (dog-food-label case).

## Order of work

1. Slice 5 branch → TDD reconciler + spooled bodies + uploader seam + path
   monitor seam → tests green → build green → adversarial review → fold → merge.
2. Slice 6 branch → TDD seams + fallback selection + template upgrade + pipeline
   wiring → tests green → build green → adversarial review → fold → merge.
3. Update `docs/HANDOFF-SLICES-2-4.md` (or a new handoff) with what landed and
   the HITL checklist for both slices.

## Status log

- (append progress here as slices land)
