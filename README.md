# Pi Agent (macOS)

A native macOS app — SwiftUI shell hosting a supervised, bundled Pi Runtime. The Node/Runtime substrate lives in this repository only as the embedded session daemon that the Swift app supervises; there is **no web UI and no npm publishing**.

## What this is

- `macos/PiAgent` — the SwiftUI app: project library, thread navigation, transcript, SwiftTerm terminal, workspace/git panels, Keychain credentials, migration/erase/uninstall flows.
- `macos/PiAgentRuntime` — the runtime bundle template (Node + Pi SDK + `node-pty` + this repo's `dist`), embedded into `Pi Agent.app` with a verified manifest.
- `src/server` + `src/sessiond` — the Node session daemon the app launches and supervises over a Unix socket (the "Native Contract": health/hello, sessions, prompt, terminal, workspace, git, checkpoints, notifications, auth providers).
- `scripts/macos/` — build, verify, and runtime smoke scripts.

Why npm at all? **Pi agent itself is Node.** The Swift shell is the product; the bundled Runtime is the engine it supervises. npm is used only as the build tool for that Node substrate (and the `npm ci` inside the runtime bundle) — nothing here is published to npm anymore.

## Build

Requirements: Xcode Command Line Tools (Swift), Node.js ≥ 22.19, npm.

```bash
npm install
./scripts/macos/build-app.sh release   # ~server build + swift release + runtime bundle
./scripts/macos/verify-app.sh          # bundle + manifest + internal runtime smoke
./scripts/macos/smoke-runtime.sh       # full native-contract runtime smoke (slow)
```

The app lands at `build/macos/Pi Agent.app`. Copy it to `/Applications`:

```bash
cp -R "build/macos/Pi Agent.app" "/Applications/Pi Agent.app"
```

## Development

- Swift sources: `macos/PiAgent/Sources/` (app, core client, helpers, contract check).
- Swift tests: `macos/PiAgent/Tests/` (PiAgentCore unit tests, swift-testing).
  Run with `scripts/macos/test-native.sh`; on Command Line Tools-only machines the
  suite compile-verifies but cannot execute (Testing.framework rpath bug) — a full
  Xcode install runs it with plain `swift test`.
- Server sources: `src/server/`, `src/sessiond/`.
- Validate the Node side with `npm run verify` (typecheck + lint + knip + tests).
- The runtime bundle is assembled by `scripts/macos/build-runtime.mjs` with a SHA-256 manifest; `verify-app.sh` re-validates it.

## Known dependency advisories

`npm audit` reports a handful of remaining advisories (`undici`, `brace-expansion`, `protobufjs`) nested under `@earendil-works/pi-coding-agent`'s own `npm-shrinkwrap.json`. npm overrides cannot reach them and the upstream package pins the same versions at 0.83.0, so the fix is to bump `pi-coding-agent` when upstream releases a patched build. Practical exposure is nil: the session daemon listens only on a Unix socket, `undici` is only an outbound client for trusted AI APIs, and `brace-expansion` only parses local globs.

## Repo layout

- `macos/PiAgent/` — Swift package (app + `PiAgentCore` + helper executables + `PiAgentContractCheck`).
- `src/` — TypeScript server/sessiond/shared/plugin-api, compiled into `dist/` (no browser client).
- `extensions/`, `pi-web-plugins/` — Pi extension surface bundled into the runtime.
- `docs/` — design and integration notes (`macos-native-app-plan.md`, `macos-pi-runtime-integration.md`).

## License

MIT. See [LICENSE](LICENSE).
