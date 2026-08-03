---
name: pi-web-release-and-local-install
description: Release the current PI WEB working tree to npm and install the published version on this Mac. Use when asked to prepare a PI WEB release, publish or version `@realchendahuang/dahuang-pi-web-ui`, make the repository clean, globally install the result, or verify the local native-service/runtime boundary after a release.
---

# PI WEB Release and Local Install

Use this workflow only from the PI WEB repository root. It supplements `npm-release-local`, `changeset-changelog`, `testing-guide`, and `documentation-guide`; read each applicable Skill before editing its area.

## Safety gates

1. Inspect `package.json`, `package-lock.json`, `.changeset/config.json`, pending `.changeset/*.md`, `git status --short --branch`, and the absence of `.github/workflows/`.
2. Do not silently include, discard, stash, or overwrite unrelated dirty work. Ask before release inclusion unless the user explicitly authorizes committing the whole working tree.
3. Keep non-breaking Changesets as `patch`. Do not create a major release without explicit authorization.
4. Do not expose npm tokens. Use the local npm configuration only through normal npm commands.
5. Never call a service restart automatically when active sessions might exist. Report the exact restart boundary after the release.

## Prepare the change

1. Make the requested product/documentation changes and add focused tests where behavior changed.
2. Add one concise, user-facing patch Changeset for every new published user-visible change that is not already represented by a pending Changeset. Do not write `CHANGELOG.md` by hand before versioning.
3. Run focused tests first, then `npm run typecheck`, `git diff --check`, and `npm run changelog:status`.

## Version deterministically

Compute the target as `MAJOR.YYYYMM.PATCH` using the local release date:

1. Keep the current major unless the user explicitly authorizes a breaking release.
2. Use the current month for `YYYYMM`; use patch `0` for the first release in that month, otherwise increment the current patch.
3. Check `npm view @realchendahuang/dahuang-pi-web-ui@<target> version`; if it exists, increment only `PATCH` until unused.
4. Run `npm run release:version`.
5. Enforce the calculated version with `npm version <target> --no-git-tag-version`.
6. Ensure the generated `CHANGELOG.md` heading matches `<target>`.
7. Run `npm install --package-lock-only` and require all three versions to match: `package.json`, `package-lock.json.version`, and `package-lock.json.packages[''].version`.

## Verify, commit, and publish

Run the full release gates in this order:

```bash
npm run verify
npm run build
npm run pack:dry
git diff --check
```

Treat the Vite large-chunk message and benign test fixture clone output as warnings, not success or failure by themselves. Do not publish if any required command fails.

When checks pass:

```bash
git add -A
git commit -m "chore(release): v<target>"
git push origin <current-branch>
npm publish --access public
```

The pre-commit hook and `prepublishOnly` run additional verification. If publish output is lengthy, capture it to a temporary log, preserve its exit code, and query npm rather than guessing the outcome. If a failed or unknown publish may have reached npm, check that exact version first; never attempt to overwrite it.

## Verify the published local install

1. Wait for `npm view @realchendahuang/dahuang-pi-web-ui@<target> version dist.tarball` to return the target and tarball.
2. Install the registry artifact, not the workspace:

```bash
npm install --global @realchendahuang/dahuang-pi-web-ui@<target>
pi-web --version
npm ls --global --depth=0 @realchendahuang/dahuang-pi-web-ui
pi-web doctor
```

3. Require the CLI, global package version, and `doctor` package version to equal `<target>`.
4. If `doctor` identifies the known macOS `node-pty` `spawn-helper` execution-bit issue, apply its exact proposed `chmod +x` path, then rerun `pi-web doctor`. Do not use a broad recursive permission change.
5. If code loaded by `src/server/sessiond.ts` changed, state that the user must manually restart the session daemon. If `doctor` reports Web/UI and session daemon versions behind the installed version, ask the user to run `pi-web restart` only after active sessions are safe to interrupt.

## Final handoff

Report the released version, generated changelog source, commit and pushed branch, npm registry verification, global-install and `doctor` result, any npm install-script warning, and the remaining restart action. Confirm `git status --short --branch` is clean.
