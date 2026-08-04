#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/build/macos/Pi Agent.app}"

test -d "$app_path"
test -x "$app_path/Contents/MacOS/PiAgent"
test -x "$app_path/Contents/Helpers/PiAgentKeychainHelper"
test -f "$app_path/Contents/Resources/native-helpers-manifest.json"
runtime_root="$app_path/Contents/Resources/AgentRuntime"
test -x "$runtime_root/node/bin/node"
test -d "$runtime_root/node/lib"
test -f "$runtime_root/runtime-manifest.json"
test -f "$runtime_root/runtime-launcher.mjs"
test -f "$runtime_root/dist/server/sessiond.js"
test -f "$runtime_root/node_modules/@earendil-works/pi-coding-agent/package.json"
plutil -lint "$app_path/Contents/Info.plist"
file "$app_path/Contents/MacOS/PiAgent"
node -e '
const { createHash } = require("node:crypto");
const { readFileSync } = require("node:fs");
const [helperPath, manifestPath] = process.argv.slice(1);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const hash = createHash("sha256").update(readFileSync(helperPath)).digest("hex");
if (manifest.schemaVersion !== 1 || manifest.keychainHelper?.path !== "Contents/Helpers/PiAgentKeychainHelper" || manifest.keychainHelper?.sha256 !== hash) throw new Error("Native Keychain helper manifest did not match helper bytes");
' "$app_path/Contents/Helpers/PiAgentKeychainHelper" "$app_path/Contents/Resources/native-helpers-manifest.json"
"$runtime_root/node/bin/node" "$runtime_root/runtime-launcher.mjs" --verify-only
"$repo_root/scripts/macos/smoke-runtime.sh" "$app_path"
printf 'Verified unsigned %s\n' "$app_path"
