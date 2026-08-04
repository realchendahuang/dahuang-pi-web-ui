#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/build/macos/Pi Agent.app}"

test -d "$app_path"
test -x "$app_path/Contents/MacOS/PiAgent"
runtime_root="$app_path/Contents/Resources/AgentRuntime"
test -x "$runtime_root/node/bin/node"
test -d "$runtime_root/node/lib"
test -f "$runtime_root/runtime-manifest.json"
test -f "$runtime_root/runtime-launcher.mjs"
test -f "$runtime_root/dist/server/sessiond.js"
test -f "$runtime_root/node_modules/@earendil-works/pi-coding-agent/package.json"
plutil -lint "$app_path/Contents/Info.plist"
file "$app_path/Contents/MacOS/PiAgent"
"$runtime_root/node/bin/node" "$runtime_root/runtime-launcher.mjs" --verify-only
"$repo_root/scripts/macos/smoke-runtime.sh" "$app_path"
printf 'Verified unsigned %s\n' "$app_path"
