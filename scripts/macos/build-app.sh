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

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/PiAgent"
cp "$package_root/Info.plist" "$app_path/Contents/Info.plist"
node "$repo_root/scripts/macos/build-runtime.mjs" \
  --output "$app_path/Contents/Resources/AgentRuntime" \
  --node "$node_executable"

printf 'Built unsigned %s\n' "$app_path"
