#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/build/macos/Pi Agent.app}"

test -d "$app_path"
test -x "$app_path/Contents/MacOS/PiAgent"
codesign --verify --deep --strict "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
file "$app_path/Contents/MacOS/PiAgent"
printf 'Verified %s\n' "$app_path"
