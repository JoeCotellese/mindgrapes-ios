<!-- ABOUTME: The exact App Store Connect privacy questionnaire answers for MindGrapes, with the evidence behind each. -->
<!-- ABOUTME: Must stay consistent with MindGrapes/PrivacyInfo.xcprivacy and MindGrapesWatch/PrivacyInfo.xcprivacy. -->

# App privacy questionnaire — MindGrapes

The answers to paste into App Store Connect → App Privacy. Derived from the same
reading of the code as `MindGrapes/PrivacyInfo.xcprivacy` and
`MindGrapesWatch/PrivacyInfo.xcprivacy`. **If this file and those manifests ever
disagree, one of them is wrong and it is a bug, not a discrepancy to note.**

The questionnaire covers the whole app record, which means the iPhone/iPad app
and the embedded watch app together. The watch collects a strict subset of what
the phone does (text and location, no photos), so the union below is the phone's
answer set.

---

## Gate question: does this app collect data?

**Yes.**

Not because a company receives anything. Apple's definition of "collect" is
transmission off the device for longer than servicing the request in real time,
and a capture is stored permanently on the server at the other end. That the
server belongs to the user rather than to the developer changes who holds the
data, not whether it left the device.

## Tracking

**No**, on every data type, and no tracking domains.

There is no third-party code to track with. `MindGrapesKit/Package.swift`
declares zero package dependencies, and no analytics SDK, ad SDK, attribution
SDK, or crash reporter is linked. `NSPrivacyTracking` is `false` and
`NSPrivacyTrackingDomains` is empty in both manifests.

## Data types: collected

Three. All three: **Linked to the user**, **not used for tracking**, purpose
**App Functionality** only.

"Linked to the user" is the honest answer even though the developer never sees
any of it. A capture lands on the user's authenticated account on their own
server; there is no anonymous mode and no de-identification step.

### 1. User Content → Photos or Videos

- Collected: Yes · Linked: Yes · Tracking: No · Purpose: App Functionality
- What: the downscaled JPEG derivative of a photo capture, at most 1024 px on
  its longest side. The full-resolution original never leaves the device, and
  downscaling strips EXIF including any GPS the camera wrote (SPEC 7.2).
- Manifest key: `NSPrivacyCollectedDataTypePhotosorVideos` (phone only).

### 2. User Content → Other User Content

- Collected: Yes · Linked: Yes · Tracking: No · Purpose: App Functionality
- What: the note text the user types or dictates, the on-device OCR text, the
  on-device generated photo description, the reverse-geocoded place label, and
  any free-form labels. This is the capture payload of SPEC 6.3 and 6.4.
- Manifest key: `NSPrivacyCollectedDataTypeOtherUserContent` (phone and watch).

### 3. Location → Precise Location

- Collected: Yes · Linked: Yes · Tracking: No · Purpose: App Functionality
- What: latitude and longitude on a capture, and only while the Include Location
  toggle is on. When In Use authorization only, a one-shot `requestLocation()`,
  no background location, no continuous updates. A capture ships without
  coordinates rather than waiting for a fix (SPEC 9).
- **Precise, not Coarse.** The app asks CoreLocation for
  `kCLLocationAccuracyHundredMeters`
  (`MindGrapesKit/Sources/MindGrapesKit/Capture/SystemLocationProvider.swift:157`).
  App Store Connect draws the coarse line at 3 km²; 100 m resolves far finer, so
  answering Coarse would be wrong even though the app is not asking for the best
  fix available.
- Manifest key: `NSPrivacyCollectedDataTypePreciseLocation` (phone and watch).

## Data types: not collected

Answer **No** to every one of these. The non-obvious ones carry their reasoning,
because "we didn't think about it" and "we checked" look identical in the form.

- **Contact Info** (name, email, phone, physical address, other) — no. The app
  never asks for any of it. Sign-in is OAuth against the user's own server; no
  profile, email, or name scope is requested, and nothing is read back from the
  token response beyond the tokens themselves.
- **Health & Fitness** — no.
- **Financial Info** — no. No purchases, no payment.
- **Location → Coarse Location** — no. See Precise, above; answering both would
  double-count one behavior.
- **Sensitive Info** — no.
- **Contacts** — no. The address book is never read. `Person` exists in the data
  model and the wire format supports a `people` field, but nothing in the
  shipping UI or the shipping intents populates it, so nothing is sent.
- **User Content → Audio Data** — no, and this one is worth stating explicitly
  because the app is dictation-forward. Dictation on both platforms is the
  system's: the iOS keyboard mic and the watch's `TextFieldLink` input sheet.
  The audio is Apple's to handle and the app receives only the finished string.
  MindGrapes has no microphone code, no `SFSpeechRecognizer`, and no
  `NSMicrophoneUsageDescription`.
- **User Content → Emails or Text Messages, Gameplay Content, Customer Support**
  — no.
- **Browsing History** — no.
- **Search History** — no. There is no search surface.
- **Identifiers → User ID** — no. See the judgment call below.
- **Identifiers → Device ID** — no. No IDFA, no IDFV, no vendor identifier is
  read or transmitted.
- **Purchases** — no.
- **Usage Data** (product interaction, advertising data, other) — no. There is
  no analytics of any kind. `OSLog` output stays on the device.
- **Diagnostics** (crash data, performance data, other) — no crash reporter and
  no performance SDK.
- **Other Data** — no.

## The one judgment call: Identifiers → User ID

Answered **No**, and the reasoning is here so it can be argued with rather than
rediscovered.

Signing in yields OAuth tokens that are stored in the Keychain and sent as a
bearer on every capture, so in a literal sense each upload carries something
that identifies an account. It is answered No because the questionnaire asks
what the app *collects* — what it transmits to a party who then holds it — and
the token is a credential presented to the server that issued it, not an
identifier gathered from the user and shipped somewhere. The server already
knows who its own account holder is; nothing new is disclosed to anyone.

The "Linked to the user" answer on the three collected types is where the
account association is already declared, and declaring User ID as well would
double-count the same fact.

If a reviewer disagrees, flipping this to Yes / Linked / App Functionality is a
one-field change with no code consequence. It is not worth an argument.

## Consistency check against the manifests

- Phone `NSPrivacyCollectedDataTypes`: PhotosorVideos, OtherUserContent,
  PreciseLocation. Matches the three Yes answers above.
- Watch `NSPrivacyCollectedDataTypes`: OtherUserContent, PreciseLocation. A
  subset; the watch has no camera.
- Both manifests: `NSPrivacyTracking` false, `NSPrivacyTrackingDomains` empty.
  Matches "No" on tracking everywhere above.
- Required-reason APIs are a separate mechanism and do not appear in this
  questionnaire at all. Phone declares `CA92.1` (App Group user defaults), watch
  declares `1C8F.1` (its own user defaults). Neither is a data-collection claim.

## Still outstanding

- **Privacy Policy URL.** Required, and a different field from everything above.
  Whatever it says has to agree with this page: no tracking, no third parties,
  data goes only to a server the user operates. TODO.
- **Account deletion.** Guideline 5.1.1(v) requires in-app account deletion from
  apps that support account *creation*. MindGrapes creates no accounts; it signs
  in to one that already exists on the user's own server. Sign-out clears the
  tokens and the local outbox (`SettingsView.signOut`). Expected to be
  not applicable, but confirm before submitting rather than after.
