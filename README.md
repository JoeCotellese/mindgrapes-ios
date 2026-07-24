# MindGrapes iOS

Capture surface for a self-hosted [Mind Grapes](https://github.com/JoeCotellese/mindgrapes-server)
server. Text and photos, from the app, Siri, Shortcuts, the Share Sheet, and
the Watch. Not a browsing app: the point is getting something into the brain
in under five seconds.

## Documents

- `docs/SPEC.md` is the technical specification. Read section 2 (decided
  items) before proposing a design change; the alternatives have been
  weighed.
- `docs/PHASE1-ISSUES.md` is the Phase 1 work breakdown, one item per branch,
  each with a verification mode.

## Layout

- `MindGrapesKit/` is a local Swift package holding the client, auth, queue,
  and capture pipeline. It has no UIKit dependency and declares macOS, so its
  test suite runs on the host with no simulator.
- `MindGrapes/` is the iOS app target.
- `project.yml` is the XcodeGen spec. **The `.xcodeproj` is generated and
  gitignored**; edit `project.yml` and run `make generate`.

## Getting started

```sh
make test       # MindGrapesKit unit suite on the host, no simulator
make generate   # regenerate MindGrapes.xcodeproj from project.yml
make build      # build the app for the simulator
make help       # list targets
```

`make test` is the signal to develop against: it needs no simulator, no
server, and no network. Most of the Phase 1 logic is verifiable there.

Device builds need a signing team. None is checked in; set `DEVELOPMENT_TEAM`
locally rather than committing it.

## Server dependency

The app talks to a Mind Grapes server over its bearer-authed REST doors, not
over MCP (SPEC section 2, decision 1). Phase 1 needs server-side changes
tracked as issues in the server repo; they are summarized in SPEC section 14.

The server URL is configured at runtime, so this app works against any
Mind Grapes deployment. Nothing about a particular host is baked into the
binary, which is why the OAuth callback uses a private-use scheme rather than
a Universal Link (SPEC section 5.2).

## License

[MIT](LICENSE) &copy; 2026 Joe Cotellese
