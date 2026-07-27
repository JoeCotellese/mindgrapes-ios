<!-- ABOUTME: Draft App Store listing copy for MindGrapes, to be pasted into App Store Connect by hand. -->
<!-- ABOUTME: Every field carries its character count against Apple's limit; nothing here is published automatically. -->

# App Store listing — MindGrapes

Draft, not final. Nothing in this repo publishes to App Store Connect; these
fields are for a human to paste into the product page.

Counts below are literal `len()` of the exact string in the fenced block. Recount
after any edit: over-limit copy is rejected at save time, not at review time.

The one thing every field is built around: **this app is useless without a
Mind Grapes server the buyer hosts themselves.** That is a hard qualifier, so it
goes in the name, in the promo text, and in the first sentence of the
description. Someone without a server should bounce before they install, not
after they hit the connect screen and leave a one-star review.

---

## App Name — 29/30

```
MindGrapes: Self-Hosted Notes
```

The 30 characters Apple weights highest, so brand alone would waste them.
"Self-Hosted" is both the qualifier and the term the homelab audience actually
searches. "Notes" is the app's own vocabulary, not a stretch: the capture screen
says "Capture a note", the Siri shortcut is "MindGrapes Note", and
`CaptureNoteIntent` conforms to the `.notes.createNote` app schema. The
description then says plainly what kind of notes app it is not.

Alternates, if the "Notes" framing sets the wrong expectation:

- `MindGrapes: Private Capture` — 27/30. Loses the self-hosted keyword.
- `MindGrapes` — 10/30. Wastes 20 indexed characters.

## Subtitle — 28/30

```
Your own server, not a cloud
```

Second-highest weight, and the first line a browser reads. States the
differentiator as a benefit and indexes `server`, `cloud`, `own`, none of which
the name already covers.

Alternates:

- `Self-hosted second brain inbox` — 30/30. Stronger keywords, but repeats
  "self-hosted" from the name, which is wasted index space.
- `Notes to your own server` — 24/30. Repeats "notes" from the name.

## Keywords — 95/100

```
homelab,selfhosting,offline,journal,diary,memory,jot,photo,ocr,siri,shortcuts,dictation,private
```

No spaces after commas: a space is a wasted indexed character. Deliberately
excludes anything already in the name or subtitle (`mindgrapes`, `self`,
`hosted`, `notes`, `server`, `cloud`), the category name, and the word "app" —
Apple indexes all of those on its own.

`homelab` and `selfhosting` are the qualified-buyer terms and earn their space
even though the audience is small; a small audience that can actually use the
app beats a large one that cannot.

## Promotional Text — 165/170

```
Requires a Mind Grapes server you run yourself. If you have one, this is the fastest way to feed it: type, dictate, or shoot, and it goes up when you're back online.
```

The only field editable without shipping a build, so it is the cheap place to
test message angles later. Not indexed, so it is written purely to qualify and
convert.

Alternate: `You bring the server, this brings the five-second capture. Type,
dictate, or shoot; it queues offline and lands on your own Mind Grapes install,
and nowhere else.` — 162/170.

## Description — 2652/4000

Only the first three lines show before the "more" fold, so the qualifier and the
promise are both above it.

```
MindGrapes needs a Mind Grapes server that you host yourself. No server, no app. That is the first thing to know, and it is also the entire point.

If you run one, this is the shortest path from a thought to your own brain: open, type or dictate, done in a few seconds. Photos too. Nothing waits on a network.

WHERE YOUR CAPTURES GO

To the address you type in during setup, over TLS, and nowhere else. There is no MindGrapes account, no MindGrapes cloud, no analytics, no crash reporter, no ads, and no third-party code in the app at all. Every capture is sent marked private.

CAPTURE

- Type a note, or dictate it with the keyboard's mic.
- Shoot a photo or pick one. It is downscaled on device before it goes anywhere, and the full-size original never leaves.
- On-device text recognition reads what is in the photo, and an on-device model turns that into a plain sentence that still makes sense a year later. Both run on your device. On hardware without Apple Intelligence, a plain template stands in and capture never fails for the lack of it.
- Attach where you were, or don't. One toggle, asked for honestly during setup rather than sprung on you at the first capture.

WHEN YOU ARE OFFLINE

A capture is written to a durable local queue before anything is sent, and goes up when the connection comes back. Subway, plane, dead zone: capture anyway.

HANDS FREE

"Hey Siri, capture a thought in Mind Grapes." The note reaches your server without the app coming to the front. The same actions appear in Shortcuts and Spotlight, so you can put one on the Action Button and never open the app at all.

ON YOUR WRIST

The Apple Watch app is one button and a dictation field. It takes the location fix on your wrist rather than on the phone when it catches up, so a thought captured on a run records where you actually were. It holds no credentials and no queue of its own; it hands each capture to your iPhone, and tells you plainly whether the phone has it yet.

WHAT THIS IS NOT

- Not a place to browse, search, or edit what you captured. Capture is append-only. Reading happens on your server, through whatever AI client you already talk to.
- Not a photo library. Photos here are receipts for something you saw, not an archive.
- Not a sync service. There is no cloud in the middle, because there is no company in the middle.

BEFORE YOU INSTALL

You need a running Mind Grapes server your device can reach, and an account on it. Setup is a URL and a sign-in. If that reads like work rather than like a feature, this app is not for you, and that is a fine outcome for both of us.

The app is open source: github.com/JoeCotellese/mindgrapes-ios
```

### What the description deliberately does not claim

Checked against the two shipping targets in `project.yml`, not against
`docs/SPEC.md` section 10, which describes the whole roadmap:

- **No Share Sheet.** There is no `MindGrapesShare` extension target.
- **No Control Center control and no widget.** There is no widget extension
  target.
- **No Home Screen quick actions.** No `UIApplicationShortcutItem`s are declared.
- **No watch complication and no Smart Stack widget.** Still open as issue #25.
- **No CarPlay.** SPEC 10.9 rules it out on entitlement grounds.
- **No claim that a capture completes after the app is killed.** Issue #21 is
  open: uploads still run in-process, so "goes up when the connection comes back"
  is scoped to the app being alive, and the copy says nothing stronger.
- **No browse, search, or edit surface.** The shipped UI is a capture screen, a
  connect screen, and a settings sheet.

## What's New — 712/4000

```
First release.

MindGrapes is a capture surface for a Mind Grapes server you host yourself.

- Type or dictate a note and it is on your server in seconds.
- Shoot or pick a photo. It is downscaled on device, read with on-device text recognition, and described by an on-device model before anything is uploaded.
- Optional location on a capture, off or on from one toggle.
- Captures queue on device when you are offline and go up when the connection returns.
- Siri, Spotlight, and Shortcuts: "Hey Siri, capture a thought in Mind Grapes."
- An Apple Watch app for dictating a capture from your wrist, with the location fix taken on the wrist.
- Sign in to your own server over OAuth. Tokens stay in the Keychain.
```

App Store Connect does not require release notes on a first submission. Fill it
in anyway: it is the version-history entry people read a year from now.

---

## URLs

- **Support URL** — TODO. Required; App Store Connect will not accept the
  version without one. `https://github.com/JoeCotellese/mindgrapes-ios/issues`
  is a legitimate answer for an open-source app and costs nothing to stand up.
- **Marketing URL** — TODO, optional. `https://github.com/JoeCotellese/mindgrapes-ios`
  if nothing better exists by submission time.
- **Privacy Policy URL** — TODO. Required for every app, no exceptions, and it
  is a separate field from the privacy questionnaire. See
  `privacy-nutrition-label.md`; the policy has to say the same things the
  questionnaire and `PrivacyInfo.xcprivacy` say.

## Category, age rating, price

TODO, all of them. Nothing in the repo decides these.

- Primary category: Productivity is the obvious fit. Utilities is the alternate.
- Age rating: nothing in the app generates content, so the questionnaire should
  come out 4+. Worth double-checking the user-generated-content questions, since
  captures are user content, but they are private to one person's own server with
  no sharing, no feed, and no other users.
- Price tier and whether this is even a public listing rather than TestFlight-only.

## Notes for App Review — the real submission risk

**A reviewer cannot use this app.** It gates on a sign-in to a Mind Grapes
server that Apple does not have, and the connect screen is the whole app until
that succeeds. Submitting without solving this is a near-certain rejection under
guideline 2.1, "we were unable to review your app because we could not sign in."

Two things go in the App Store Connect submission form, and neither exists yet:

1. **A demo account.** A reachable Mind Grapes instance, publicly resolvable
   from Apple's network (not Tailscale-only, which is what the connect screen's
   own `brain.example.ts.net` placeholder implies the maintainer runs), with a
   throwaway account whose credentials go in the demo-account fields. Expect it
   to receive junk captures.
2. **Review notes** spelling out that the app is a client for self-hosted
   server software, that the demo server is provided solely for review, and
   where the server itself lives
   (`https://github.com/JoeCotellese/mindgrapes-server`).

TODO both. This is a bigger blocker than any copy on this page.
