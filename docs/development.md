# Development workflow

Use this workflow when iterating on PI WEB while a session daemon is already running. It keeps active Pi sessions alive while the browser UI, API, and browser plugins reload from this checkout.

## Start rapid UI development

From the repository root:

```bash
npm install
npm run dev:ui
```

Open <http://localhost:31416> and keep that tab open. Vite applies client-side changes through HMR. Changes to the web/API server restart through `tsx watch`; browser-plugin changes rebuild through the plugin watcher, so reload the browser tab after changing a plugin module.

`dev:ui` starts two development processes:

- Vite on port `31416`, serving the source client and HMR.
- Web/API plus the browser-plugin watcher on port `31417`.

The Vite proxy sends `/api` and `/pi-web-plugins` to that development API. Port `31417` intentionally differs from the normal installed PI WEB API on `31415`, so the development checkout does not replace or interrupt it.

If `31417` is occupied, select another development API port before starting the command:

```bash
PI_WEB_DEV_API_PORT=31418 npm run dev:ui
```

Use the Vite URL rather than `http://127.0.0.1:31415` while reviewing changes.

## Session daemon ownership

Keep the session daemon long-lived and separate:

```bash
npm run start:sessiond
```

Do not use `npm run dev` for ordinary UI iteration: it starts a watch-mode session daemon, so daemon restarts can stop active sessions. Restart the daemon manually only when a change affects `src/server/sessiond.ts`, session runtime ownership, the session-daemon protocol, or another daemon-only code path.

## Verify and promote an accepted iteration

Before treating an iteration as ready:

```bash
npm run verify
npm run build
npm run pack:dry
```

The development servers are only for previewing source changes. Installing a built version into the system service and publishing an npm release are separate, deliberate steps. User-visible package changes need a Changeset; prepare a release only after the reviewed changes are committed and ready to ship.
