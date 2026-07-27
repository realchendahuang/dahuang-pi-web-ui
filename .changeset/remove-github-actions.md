---
"@realchendahuang/dahuang-pi-web-ui": patch
---

Remove the GitHub Actions workflows (`ci.yml` and `publish.yml`).

PI WEB no longer publishes through GitHub Actions and will not use GitHub Actions for any workflow going forward. Local verification (`npm run verify`), builds, and `npm install -g .` / `npm pack` remain the supported paths; release tags and GitHub Releases are still cut manually.
