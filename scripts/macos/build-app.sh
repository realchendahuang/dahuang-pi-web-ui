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
uninstaller_helper_path="$(swift build --package-path "$package_root" --configuration "$configuration" --show-bin-path)/PiAgentUninstaller"
data_eraser_helper_path="$(swift build --package-path "$package_root" --configuration "$configuration" --show-bin-path)/PiAgentDataEraser"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Helpers"
cp "$binary_path" "$app_path/Contents/MacOS/PiAgent"
cp "$keychain_helper_path" "$app_path/Contents/Helpers/PiAgentKeychainHelper"
cp "$uninstaller_helper_path" "$app_path/Contents/Helpers/PiAgentUninstaller"
cp "$data_eraser_helper_path" "$app_path/Contents/Helpers/PiAgentDataEraser"
cp "$package_root/Info.plist" "$app_path/Contents/Info.plist"
app_version="$(node -p 'require("./package.json").version')"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_version" "$app_path/Contents/Info.plist"
cp "$package_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Compile the checked-in 1024px source icon into a full .icns set. Regenerate
# the source with: swift scripts/macos/generate-app-icon.swift macos/PiAgent/Resources/AppIcon.png
icon_source_png="$package_root/Resources/AppIcon.png"
iconset_dir="$build_root/AppIcon.iconset"
rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
for spec in icon_16x16.png=16 icon_16x16@2x.png=32 icon_32x32.png=32 icon_32x32@2x.png=64 icon_128x128.png=128 icon_128x128@2x.png=256 icon_256x256.png=256 icon_256x256@2x.png=512 icon_512x512.png=512 icon_512x512@2x.png=1024; do
  sips -z "${spec##*=}" "${spec##*=}" "$icon_source_png" --out "$iconset_dir/${spec%%=*}" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$app_path/Contents/Resources/AppIcon.icns"
node -e '
const { createHash } = require("node:crypto");
const { readFileSync, writeFileSync } = require("node:fs");
const [keychainHelperPath, uninstallerHelperPath, dataEraserHelperPath, noticesPath, manifestPath] = process.argv.slice(1);
const hash = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
writeFileSync(manifestPath, JSON.stringify({
  schemaVersion: 1,
  keychainHelper: { path: "Contents/Helpers/PiAgentKeychainHelper", sha256: hash(keychainHelperPath) },
  uninstallerHelper: { path: "Contents/Helpers/PiAgentUninstaller", sha256: hash(uninstallerHelperPath) },
  dataEraserHelper: { path: "Contents/Helpers/PiAgentDataEraser", sha256: hash(dataEraserHelperPath) },
  thirdPartyNotices: { path: "Contents/Resources/THIRD_PARTY_NOTICES.md", sha256: hash(noticesPath) },
}, null, 2) + "\n");
' "$app_path/Contents/Helpers/PiAgentKeychainHelper" "$app_path/Contents/Helpers/PiAgentUninstaller" "$app_path/Contents/Helpers/PiAgentDataEraser" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/native-helpers-manifest.json"
node "$repo_root/scripts/macos/build-runtime.mjs" \
  --output "$app_path/Contents/Resources/AgentRuntime" \
  --node "$node_executable"

printf 'Built unsigned %s\n' "$app_path"
