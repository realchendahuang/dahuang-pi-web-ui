#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
package_root="$repo_root/macos/PiAgent"
configuration="${1:-release}"
build_root="$repo_root/build/macos"
app_path="$build_root/Pi Agent.app"

swift build --package-path "$package_root" --configuration "$configuration"
binary_path="$(swift build --package-path "$package_root" --configuration "$configuration" --show-bin-path)/PiAgent"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/PiAgent"
cp "$package_root/Info.plist" "$app_path/Contents/Info.plist"

# Ad-hoc signing makes the local artifact executable. Release builds must be
# re-signed with the team's Developer ID before distribution or notarization.
codesign --force --deep --sign - "$app_path"

printf 'Built %s\n' "$app_path"
