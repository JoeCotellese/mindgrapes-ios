# Spec: session restore + settings/sign-out (Slice 7 subset, #16/#18)

## Problem

The app forces the OAuth sign-in screen on every launch. Tokens already persist
in the Keychain (`TokenStore`), but nothing restores the session: `SignInView`
is the hardcoded root, so the user re-taps Sign in and redoes OAuth each launch.
There is also no way to sign out.

## Goal

1. **Stay signed in.** On launch, if the Keychain holds usable credentials, go
   straight to capture; otherwise show sign-in. The decision is local and
   offline-safe (no network, no metadata discovery).
2. **Settings + sign out.** From capture, reach a settings screen that shows the
   connected server and a Sign out action.

## Behavior

- **Session gate:** `TokenStore(accessGroup: nil).hasUsableAccessToken()`. A
  Keychain error resolves to "not signed in" (safe default). `accessGroup: nil`
  matches the rest of the app (the -34018 workaround; the shared group returns
  with the extension).
- **Sign out (SPEC 5.3):** drop the tokens, **keep** the DCR registration
  (`deleteTokens`, not `deleteAll`), so re-auth reuses the stored `client_id`
  and does not repeat Dynamic Client Registration. Keep the persisted server URL
  so the sign-in screen is pre-filled. Then clear the process-global
  `AppComposition` cache and return to sign-in.
- **Cache invalidation:** `AppComposition.reset()` nils the cached composition so
  a re-sign-in builds a fresh graph (new `AuthManager` reading the new tokens)
  rather than the stale one holding the just-deleted credentials. This is the
  cache-clear the composition's own ponytail note deferred to "when Slice 7 adds
  sign out".
- **Revive parked captures on sign-in:** on a successful sign-in, call
  `queue.resumeAfterAuth()` so any captures parked by a dead refresh (SPEC 8.5)
  drain once credentials are back. This is the Slice-1 "must-not-forget wiring".

## Scope / non-goals

- No QR onboarding (still manual URL entry; that is the rest of #16).
- No recent-captures/queue-status list (the rest of #18).
- No change-server/disconnect (`deleteAll`) flow yet; sign out keeps the server.

## Acceptance (HITL, simulator/device)

1. Sign in once, force-quit, relaunch → lands on capture without a sign-in tap.
2. Fresh install (or after sign out) → launches to the sign-in screen.
3. Sign out from settings → returns to sign-in; the server URL is still
   pre-filled; signing in again does not re-run DCR (same `client_id`) and drains
   anything that was queued.
4. Offline launch while signed in → still lands on capture (gate is local).

## Follow-up: subject-stamped outbox (deferred)

Sign-out now **clears the outbox** (`CaptureQueue.clearAll`) because records carry
no account identity, so a capture parked/pending under one identity would
otherwise be revived by `resumeAfterAuth` and delivered under the next signed-in
identity's bearer (a cross-account leak an adversarial review caught). Clearing is
the safe trade but discards unsent captures, and it does not close the narrower
path where a refresh dies mid-session (no explicit sign-out) and a *different*
identity then signs in.

The complete fix is to stamp each `CaptureRecord` with the authenticated subject
(the access token's `sub`, decodable from the JWT with no network) and to
drain/resume only records matching the currently signed-in subject; on a subject
change, clear. That preserves same-user captures across a sign-out and closes both
leak paths. Deferred as its own ticket: it touches the model, the sign-in flow
(read `sub`), and the queue's drain/resume filters. Not reachable for the current
single-user (Joe) install, but the right fix before multi-user.

## Loop-verified core (already covered)

The session-gate and sign-out semantics reduce to `TokenStore` API that
`TokenStoreTests` already pins: `hasUsableAccessToken` flips with set/delete, and
`clientID` survives `deleteTokens` (`clientIDSurvivesTokenDeletion`). The new
surface is SwiftUI views + the `AppComposition.reset()` static glue, verified by
adversarial review and HITL (no app-hosted test target exists yet — #23).
