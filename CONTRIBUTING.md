# Contributing

Read `docs/SPEC.md` section 2 before proposing a design change. The
alternatives there have been weighed and the reasons are recorded.
`docs/PHASE1-ISSUES.md` is the work breakdown; each item is one branch and
one PR.

## Build and test

```sh
make test       # MindGrapesKit unit suite on the host. No simulator, no server.
make build-kit  # package for host, iOS, and watchOS
make generate   # regenerate MindGrapes.xcodeproj from project.yml
make build      # app for the simulator
```

`make test` is the signal. It needs no simulator, no network, and no Mind
Grapes server, which is deliberate: most of the logic lives in
`MindGrapesKit` and stays host-testable.

The `.xcodeproj` and `MindGrapes/Info.plist` are generated and gitignored.
Edit `project.yml`, then `make generate`. Do not check the pbxproj in; it
would become a merge-conflict surface and a second source of truth.

Run `make hooks` once per clone. It points `core.hooksPath` at `.githooks`,
whose `pre-push` hook runs the suite before anything leaves your machine.
Nothing runs the suite server-side, so this hook is the gate; `git push
--no-verify` bypasses it when you need to push a known-red WIP branch.

## Releasing

Building and running need no Apple account: `make build` targets the
simulator with signing off. Shipping to the App Store is a separate,
maintainer-only path, and every credential for it comes from the environment
so nothing secret is committed.

Copy `.env.example` to `.env` (gitignored) and fill in an App Store Connect
API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`) plus your
`DEVELOPMENT_TEAM`. Then:

```sh
set -a; . ./.env; set +a   # load the secrets into this shell only
make release-validate      # archive + App Store validation, no submission
make release               # archive, export, and upload for real
```

Run `make release-validate` first: it catches almost everything an upload
would reject without consuming a build number. The API key's `.p8` is copied
into a private temp directory at run time and deleted on exit, never into the
repo or your home folder.

## House rules

- **TDD.** Failing test first, then the minimum code to pass.
- Every code file opens with a two-line `ABOUTME:` comment.
- Comments explain why, not what. The `ABOUTME` header is the exception.
- Never remove an existing comment unless you can show it is false.
- Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
- No `import UIKit` in `MindGrapesKit`. Platform-specific work goes behind a
  protocol seam so the logic stays host-testable.
- Nothing is named "new", "improved", "enhanced", or "v2". Today's new is
  tomorrow's old.
- Test output must be pristine. The app target builds with
  `SWIFT_TREAT_WARNINGS_AS_ERRORS`.

## Two traps that have already bitten

**SwiftData models do not cross actor boundaries.** `CaptureRecord` is a
`@Model` class and is not `Sendable`. Consumers take a `Sendable` value
snapshot, never the model. See SPEC 4.3.

**Store tests must be serialized.** Concurrent `ModelContainer` creation
segfaults inside CoreData schema setup, roughly 1 run in 10. Any test that
opens a SwiftData store belongs in a `@Suite(.serialized)`. If a suite
starts failing intermittently with a truncated log and no error text, this
is why: check for a crash report before assuming your change is at fault.

## Branching and merging

Branch from `main`. Name branches `feature/<item>-<description>` after the
breakdown item, e.g. `feature/7-keychain-store`.

Merge with **`--merge`, not `--squash`**, and do **not** pass
`--delete-branch` while any other PR targets your branch. Both of these are
scar tissue:

- Squash-merging a base branch rewrites its commits, so every branch cut
  from it diverges and reports a conflict. Each child then needs
  `git rebase --onto main <old-base-sha>` and a force-push.
- Deleting a base branch **auto-closes** every PR pointing at it, and GitHub
  will not let you retarget a closed PR. It has to be reopened as a new one.

Both happened on the first merge. Delete branches at the end, once nothing
points at them.

## Server changes

The app talks to `mindgrapes-server` over its bearer-authed REST doors, not
over MCP (SPEC section 2, decision 1). Server-side work is tracked as issues
in that repo and summarized in SPEC section 14. Its `CLAUDE.md` has its own
house rules; follow them there rather than importing these.
