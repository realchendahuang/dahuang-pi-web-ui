---
"@realchendahuang/dahuang-pi-web-ui": patch
---

Remove the GitHub Actions workflows (`ci.yml` and `publish.yml`) and switch to local npm publishing.

PI WEB no longer publishes through GitHub Actions and will not use GitHub Actions for any workflow going forward. Releases are now cut locally: add a changeset, run `npm run release:version`, commit, then `npm publish --access public` (authenticated by a granular npm access token in `~/.npmrc` that bypasses 2FA, scoped to `@realchendahuang`). The `npm-release-via-github-actions` agent skill was rewritten as `npm-release-local` to document this flow.
