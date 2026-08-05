# Agent Notes

This project is the native macOS Pi Agent app: a SwiftUI shell (`macos/PiAgent`) that supervises a bundled Node Pi Runtime. There is no web UI and no npm publishing.

## What changed vs. the old web product

- The Vite browser client (`src/client`), `pi-web` CLI, docker deployment, npm release machinery (Changesets, CHANGELOG, publish scripts) and their agent skills were **deleted**.
- npm remains only as the build tool for the Node runtime substrate: `npm install`/`npm ci` (runtime bundle), `tsc`/`vitest`/`eslint`/`knip`, and `node-pty` native module. `npm run build` compiles `src/server` + plugin API + plugins into `dist/` — no Vite, no client.
- Never re-add npm publishing, Changesets, a web client, or GitHub Actions workflows.

## Runtime ownership model

- The long-lived process is the **bundled Runtime** (session daemon, `dist/server/sessiond.js`) launched by `PiAgent` through `RuntimeSupervisor`; the Swift app supervises it over a Unix socket.
- The app is the single owner of the runtime boundary: launch nonce, socket security, project capability token, and per-connect project re-authorization live in `macos/PiAgent/Sources/PiAgentCore/`.
- Browser disconnects do not exist anymore; the app restarting does not stop the Runtime. Only closing the app's runtime lifecycle stops it.

## Service layout (local dev)

- The session daemon runs either inside the built app (`Pi Agent.app/Contents/Resources/AgentRuntime`, launcher `runtime-launcher.mjs`) or standalone via `npm run start:sessiond`.
- The standalone `pi-web-ui-dev.service` / `pi-web-sessiond.service` systemd user services from the old web era may still exist locally; they are not part of this product.

## Testing

Project-specific testing rules live in `.agents/skills/testing-guide/SKILL.md`; code conventions in `.agents/skills/code-quality-architecture/SKILL.md`; documentation guidance in `.agents/skills/documentation-guide/SKILL.md`. Use them when writing or changing tests, architecture, or user-facing docs.

Validate the Node side with `npm run verify`. Validate the native side with `scripts/macos/verify-app.sh` (fast) and `scripts/macos/smoke-runtime.sh` (full native-contract smoke; note it restarts the runtime mid-test and re-authorizes the project, mirroring app reconnect behavior).

## Documentation boundaries

`README.md` is a concise landing page for the native product. Detailed design notes live in `docs/macos-native-app-plan.md` and `docs/macos-pi-runtime-integration.md`. Use `.agents/skills/documentation-guide/SKILL.md` when writing or planning user-facing documentation.
