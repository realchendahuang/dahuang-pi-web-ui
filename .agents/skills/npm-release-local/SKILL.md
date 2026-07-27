---
name: npm-release-local
description: Use this skill whenever the user asks for a new npm version, npm release, package release, new release, version bump, publishing to npm, cutting a release, or anything similar. PI WEB publishes locally from the developer's machine with `npm publish --access public`, using a granular npm access token stored in `~/.npmrc` (2FA bypassed for that token), NOT through GitHub Actions. Uses Changesets to generate CHANGELOG.md/release notes. Trigger even for casual phrasing like "ship a release", "bump npm", "publish the package", or "make a new version".
---

# Publish `@realchendahuang/dahuang-pi-web-ui` locally

PI WEB publishes to npm **from the local machine**, not from GitHub Actions. The `.github/workflows/` directory has been removed entirely; there is no CI publish path and there will not be one.

Publishing is authenticated by a **granular npm access token** stored in `~/.npmrc` as `//registry.npmjs.org/:_authToken`. That token is scoped to the `@realchendahuang` organization, has read+write permission, is set to bypass 2FA, and expires (90 days max for write tokens). Because it bypasses 2FA, `npm publish` does not prompt for an OTP. If `npm publish` ever fails with `EOTP` or `ENEEDAUTH`, the token has expired or been revoked — the fix is to create a new granular token at <https://www.npmjs.com/settings/chendahuang/tokens/granular-access-tokens/new> (name it `pi-web-publish`, check "Bypass 2FA", Read and write, scope `@realchendahuang`, 90 days) and run `npm config set //registry.npmjs.org/:_authToken <new-token>`.

This project also uses Changesets for changelog generation. Release prep consumes `.changeset/*.md` fragments into `CHANGELOG.md` before publishing.

## Core rules

Publish from the local machine with:

```bash
npm publish --access public
```

Do NOT try to restore or use a GitHub Actions publish workflow. Do NOT run `npm version <new-version>` (it creates a local git tag as a side effect and can desync the release from the intended commit). Use `npm version --no-git-tag-version` only when enforcing a computed CalVer target.

It is OK and expected to run local safety checks and release-prep commands:

- `npm run verify`
- `npm run build`
- `npm run pack:dry`
- `npm run changelog:status`
- `npm run release:version`
- `npm version <version> --no-git-tag-version` when enforcing an exact CalVer target
- `npm install --package-lock-only` to resync the lockfile

## First inspect the repository release setup

Before acting, read:

1. `package.json` for package name (`@realchendahuang/dahuang-pi-web-ui`), current version, scripts, and package manager (npm).
2. `package-lock.json` so version bumps keep the lockfile consistent.
3. `.changeset/config.json` and pending `.changeset/*.md` files.
4. Confirm there is NO `.github/workflows/` directory (it was intentionally removed). If one reappears, stop and ask before publishing — the user does not want GitHub Actions.

## Standard release workflow

1. **Check repo state**
   - Run `git status --short --branch`.
   - Ensure you are on the intended branch (`ui-rebuild` during the rebuild; otherwise the user's current working branch).
   - If there are unrelated or user-owned uncommitted changes, pause and ask before including, stashing, or working around them.

2. **Review and normalize pending changesets**
   - Run:

     ```bash
     npm run changelog:status
     ```

   - Inspect `.changeset/*.md` files.
   - If there are no changesets but there are user-visible changes to release, pause and ask whether to add a changeset. Do not create a low-quality release note just to proceed.
   - If changesets exist, make sure their text is user-facing.
   - Non-breaking changesets must use `patch` even for new features. The package uses CalVer shaped as semver: `MAJOR.YYYYMM.PATCH`. The semver `minor` position is the release month, not feature size.
   - If a pending changeset uses `minor` for a non-breaking change, edit its frontmatter to `patch` before versioning. Do not ask the user whether to use a patch increase or date change.
   - Use `major` only when the user explicitly requests a breaking/major release.
   - If you believe the pending changes introduce a breaking change but the user has not explicitly requested a major release, pause before versioning and ask the user to confirm whether this should be released as a breaking major version or changed to remain non-breaking.

3. **Compute the CalVer version**
   - Always compute the version from the release date as `MAJOR.YYYYMM.PATCH`.
   - Use the current date at release time for `YYYYMM` (for example, `date +%Y%m`). Do not ask whether to use a same-month patch increase or a date change.
   - Keep the current `MAJOR` unless the user explicitly requests a breaking/major release. Do not infer or perform a major version bump on your own.
   - Set `PATCH` deterministically:
     - If the current package version already has the target `MAJOR` and release-month `YYYYMM`, use current patch + 1.
     - Otherwise use patch `0` for the first release of that major/month.
     - If npm already has the computed version, increment only `PATCH` until an unpublished version is found (check with `npm view @realchendahuang/dahuang-pi-web-ui@<computed> version`).
   - If the user says `patch`, `minor`, `new version`, `new release`, `publish`, or similar without an exact version, still use this CalVer algorithm. Treat `minor` as a non-breaking release request, not as permission to let Changesets increment semver minor arbitrarily.
   - If the user gives an exact version, use it only when they clearly intend that exact value. Otherwise preserve the CalVer rule above.
   - If the computed CalVer target would be lower than or equal to the current package version because of clock/version inconsistency, stop and explain the inconsistency instead of inventing a non-CalVer version.

4. **Generate changelog and version files**
   - Run the Changesets version step after normalizing non-breaking changesets to `patch`:

     ```bash
     npm run release:version
     ```

   - This consumes pending `.changeset/*.md` fragments, updates `CHANGELOG.md`, updates `package.json`, and updates the npm lockfile when applicable.
   - Changesets may produce a semver bump that does not match the computed CalVer target, especially on the first release of a new month. That is expected; enforce the computed target with:

     ```bash
     npm version <computed-calver-version> --no-git-tag-version
     ```

   - Update the newly generated `CHANGELOG.md` heading to match the computed CalVer version if Changesets used a different heading. This manual changelog heading edit is acceptable during release prep; normal development should still use changeset fragments instead.
   - Review the generated `CHANGELOG.md` section — it should be suitable as the GitHub Release notes if a GitHub Release is created later.
   - **Sync the lockfile to the final version.** `npm run release:version` updates `package.json` but does not reliably rewrite `package-lock.json`, and the CalVer-enforcing `npm version --no-git-tag-version` only touches the lock when it actually runs. Either path can leave the committed `package-lock.json` behind at the previous version, which then resurfaces as an unexpected diff after the next `npm install`. After the version is finalized, always resync the lockfile without touching `node_modules`:

     ```bash
     npm install --package-lock-only
     ```

   - Confirm the lockfile now matches `package.json` before continuing:

     ```bash
     node -e "const v=require('./package.json').version, l=require('./package-lock.json'); if (l.version!==v || l.packages[''].version!==v) { console.error('lockfile version mismatch:', l.version, l.packages[''].version, 'expected', v); process.exit(1); } console.log('lockfile in sync at', v);"
     ```

   - If the lockfile mismatch persists, stop and resolve it before committing; do not ship a release whose `package-lock.json` version disagrees with `package.json`.

5. **Run checks before publishing**
   - `npm publish` runs `prepublishOnly` (which is `npm run verify`) automatically, but it is still wise to run it first so failures are caught before the publish attempt:

     ```bash
     npm run verify
     npm run build
     npm run pack:dry
     ```

   - If checks fail, fix the issue or report it. Do not publish until the release commit is sound.

6. **Commit and push the release prep**
   - Commit only intended release changes. Typical files include:
     - `package.json`
     - `package-lock.json`
     - `CHANGELOG.md`
     - consumed/deleted `.changeset/*.md` fragments
   - Before staging, confirm `package-lock.json` is actually in the diff and carries the new version. If `git status --short` does not show `package-lock.json` as modified while `package.json` changed version, the lockfile sync in step 4 was missed — go back and run `npm install --package-lock-only`. Never commit a release where `package.json` advanced but `package-lock.json` did not.
   - Use:

     ```bash
     git add package.json package-lock.json CHANGELOG.md .changeset
     git commit -m "chore(release): v<new-version>"
     git push origin <branch>
     ```

   - If there are other intentional changes required for the release, include them deliberately and mention them.

7. **Publish to npm**
   - From the repo root, with the release commit already pushed:

     ```bash
     npm publish --access public
     ```

   - `prepublishOnly` runs `npm run verify`, then the tarball is built and uploaded. The `~/.npmrc` granular token authenticates without an OTP prompt.
   - If it fails with `EOTP`: the token does not have 2FA bypass (or was replaced) — recreate the `pi-web-publish` granular token with "Bypass 2FA" checked, set it in `~/.npmrc`, and retry.
   - If it fails with `ENEEDAUTH` / `ENEEDAUTH` empty token: the `//registry.npmjs.org/:_authToken` line is missing or the token was revoked — recreate it and run `npm config set //registry.npmjs.org/:_authToken <token>`.
   - If the npm version already exists, npm rejects with `EPUBLISHCONFLICT` / `E403`. Bump to a new version and publish a new release; never overwrite an already-published version.

8. **Verify npm registry publication**
   - Immediately after a successful publish, the npmjs.com package page is usually live within seconds, but the `registry.npmjs.org` metadata API (used by `npm view` and `npm install`) can lag by 1–3 minutes for newly published scoped packages. Poll for propagation:

     ```bash
     for i in $(seq 1 18); do
       v=$(npm view @realchendahuang/dahuang-pi-web-ui version 2>/dev/null)
       if [ -n "$v" ]; then echo "propagated: $v"; break; fi
       sleep 10
     done
     npm view @realchendahuang/dahuang-pi-web-ui version
     npm view @realchendahuang/dahuang-pi-web-ui@<new-version> dist.tarball
     ```

   - Do not declare success until `npm view` returns the new version.

9. **Optional: cut a GitHub Release (manual, no automation)**
   - There is no Actions workflow to trigger, so a GitHub Release is purely a human-readable artifact. Skip it if the user does not ask for one.
   - If the user wants one, create it from the pushed release commit using the Changesets-generated changelog section as notes:

     ```bash
     gh release create v<new-version> \
       --target <branch> \
       --title "v<new-version>" \
       --notes-file /tmp/pi-web-release-notes-v<new-version>.md
     ```

   - Do NOT expect any CI to run from the release; it exists only for notes/asset attachments.

## Reruns and special cases

- If `npm publish` failed mid-upload, the version may be partially published. Check `npm view ...@<version>`; if it exists, treat it as published and move to the next version for any retry — never republish the same version.
- If the computed CalVer version already exists on npm, increment `PATCH` and publish a new version; do not try to overwrite.
- If a publish left a dirty state (e.g. tarball uploaded but `prepublishOnly` verify failed on a later attempt), stop, inspect `npm view`, and only publish a fresh higher version.
- If the user asks to publish from a branch other than the release branch, confirm the target version and branch before publishing; the published tarball reflects whatever is in the working tree at publish time.
- Never silently fall back to `npm install -g .` or `npm pack` as a "release" — those are local-install/dev paths, not a registry publication.

## Token rotation

The `pi-web-publish` granular token expires (max 90 days for write tokens). Before it expires, or if `npm publish` starts failing with `EOTP`/`ENEEDAUTH`:

1. Go to <https://www.npmjs.com/settings/chendahuang/tokens/granular-access-tokens/new>.
2. Create a token: name `pi-web-publish`, check "Bypass two-factor authentication (2FA) for this token", Permissions "Read and write", "Only select packages and scopes" → `@realchendahuang`, Expiration 90 days.
3. `npm config set //registry.npmjs.org/:_authToken <new-token>`.
4. Delete the old token from the npm settings page.
5. Verify with `npm whoami` (returns `chendahuang`).

## Final response format

After completing or attempting a release, summarize concisely:

- Version released
- Changelog source: generated `CHANGELOG.md` section
- Commit hash and pushed branch
- `npm publish` result (success / failure reason)
- `npm view @realchendahuang/dahuang-pi-web-ui version` verification result
- GitHub Release URL, if one was created
- Any follow-up needed from the user (e.g. token rotation)
