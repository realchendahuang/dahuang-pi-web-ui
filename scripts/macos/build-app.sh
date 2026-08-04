#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
package_root="$repo_root/macos/PiAgent"
configuration="${1:-release}"
build_root="$repo_root/build/macos"
app_path="$build_root/Pi Agent.app"
node_executable="${PI_AGENT_NODE_EXECUTABLE:-$(node -p 'process.execPath')}"

if [[ ! -x "$node_executable" ]]; then
  printf 'Configured Node executable is not executable: %s\n' "$node_executable" >&2
  exit 1
fi

cd "$repo_root"
npm run build
swift build --package-path "$package_root" --configuration "$configuration"
binary_path="$(swift build --package-path "$package_root" --configuration "$configuration" --show-bin-path)/PiAgent"
keychain_helper_path="$(swift build --package-path "$package_root" --configuration "$configuration" --show-bin-path)/PiAgentKeychainHelper"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Helpers"
cp "$binary_path" "$app_path/Contents/MacOS/PiAgent"
cp "$keychain_helper_path" "$app_path/Contents/Helpers/PiAgentKeychainHelper"
cp "$package_root/Info.plist" "$app_path/Contents/Info.plist"
node -e '
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const [helperPath, manifestPath] = process.argv.slice(1);
const sha256 = createHash("sha256").update(readFileSync(helperPath)).digest("hex");
writeFileSync(manifestPath, JSON.stringify({ schemaVersion: 1, keychainHelper: { path: "Contents/Helpers/PiAgentKeychainHelper", sha256 } }, null, 2) + "\n");
' "$app_path/Contents/Helpers/PiAgentKeychainHelper" "$app_path/Contents/Resources/native-helpers-manifest.json"
node "$repo_root/scripts/macos/build-runtime.mjs" \
  --output "$app_path/Contents/Resources/AgentRuntime" \
  --node "$node_executable"

printf 'Built unsigned %s\n' "$app_path"
