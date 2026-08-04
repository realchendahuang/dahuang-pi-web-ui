#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/build/macos/Pi Agent.app}"

test -d "$app_path"
test -x "$app_path/Contents/MacOS/PiAgent"
test -x "$app_path/Contents/Helpers/PiAgentKeychainHelper"
test -x "$app_path/Contents/Helpers/PiAgentUninstaller"
test -x "$app_path/Contents/Helpers/PiAgentDataEraser"
test -f "$app_path/Contents/Resources/native-helpers-manifest.json"
test -f "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
runtime_root="$app_path/Contents/Resources/AgentRuntime"
test -x "$runtime_root/node/bin/node"
test -d "$runtime_root/node/lib"
test -f "$runtime_root/runtime-manifest.json"
test -f "$runtime_root/runtime-sbom.cdx.json"
test -f "$runtime_root/runtime-third-party-notices.json"
test -f "$runtime_root/runtime-launcher.mjs"
test -f "$runtime_root/dist/server/sessiond.js"
test -f "$runtime_root/node_modules/@earendil-works/pi-coding-agent/package.json"
plutil -lint "$app_path/Contents/Info.plist"
file "$app_path/Contents/MacOS/PiAgent"
node -e '
const { createHash } = require("node:crypto");
const { readFileSync } = require("node:fs");
const [keychainHelperPath, uninstallerHelperPath, dataEraserHelperPath, noticesPath, manifestPath] = process.argv.slice(1);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const hash = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
if (manifest.schemaVersion !== 1 || manifest.keychainHelper?.path !== "Contents/Helpers/PiAgentKeychainHelper" || manifest.keychainHelper?.sha256 !== hash(keychainHelperPath)) throw new Error("Native Keychain helper manifest did not match helper bytes");
if (manifest.uninstallerHelper?.path !== "Contents/Helpers/PiAgentUninstaller" || manifest.uninstallerHelper?.sha256 !== hash(uninstallerHelperPath)) throw new Error("Native uninstaller helper manifest did not match helper bytes");
if (manifest.dataEraserHelper?.path !== "Contents/Helpers/PiAgentDataEraser" || manifest.dataEraserHelper?.sha256 !== hash(dataEraserHelperPath)) throw new Error("Native data eraser helper manifest did not match helper bytes");
if (manifest.thirdPartyNotices?.path !== "Contents/Resources/THIRD_PARTY_NOTICES.md" || manifest.thirdPartyNotices?.sha256 !== hash(noticesPath)) throw new Error("Native third-party notices did not match their manifest hash");
' "$app_path/Contents/Helpers/PiAgentKeychainHelper" "$app_path/Contents/Helpers/PiAgentUninstaller" "$app_path/Contents/Helpers/PiAgentDataEraser" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/native-helpers-manifest.json"
"$runtime_root/node/bin/node" "$runtime_root/runtime-launcher.mjs" --verify-only
"$runtime_root/node/bin/node" "$repo_root/scripts/macos/generate-runtime-compliance.mjs" --runtime "$runtime_root" --verify
"$repo_root/scripts/macos/smoke-runtime.sh" "$app_path"
printf 'Verified unsigned %s\n' "$app_path"
