#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$repo_root/build/macos/Pi Agent.app}"
runtime_root="$app_path/Contents/Resources/AgentRuntime"
node_path="$runtime_root/node/bin/node"
launcher_path="$runtime_root/runtime-launcher.mjs"

test -x "$node_path"
test -f "$launcher_path"

runtime_test_dir="$(mktemp -d /tmp/pi-agent-runtime-smoke.XXXXXX)"
runtime_pid=""

cleanup() {
  if [[ -n "$runtime_pid" ]]; then
    kill -TERM "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_test_dir"
}
trap cleanup EXIT

PI_WEB_DATA_DIR="$runtime_test_dir/state" \
PI_WEB_CONFIG="$runtime_test_dir/config.json" \
PI_WEB_SESSIOND_SOCKET="$runtime_test_dir/sessiond.sock" \
"$node_path" "$launcher_path" >"$runtime_test_dir/runtime.log" 2>&1 &
runtime_pid=$!

for attempt in $(seq 1 80); do
  if curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" http://pi-agent/health >"$runtime_test_dir/health.json"; then
    break
  fi
  sleep 0.125
  if [[ "$attempt" == "80" ]]; then
    cat "$runtime_test_dir/runtime.log"
    exit 1
  fi
done

curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" http://pi-agent/runtime/hello >"$runtime_test_dir/hello.json"
test "$(stat -f '%Lp' "$runtime_test_dir")" = "700"
test "$(stat -f '%Lp' "$runtime_test_dir/sessiond.sock")" = "600"
"$node_path" --input-type=module -e '
import { readFile } from "node:fs/promises";
const [healthPath, helloPath] = process.argv.slice(1);
const health = JSON.parse(await readFile(healthPath, "utf8"));
const hello = JSON.parse(await readFile(helloPath, "utf8"));
if (health.ok !== true) throw new Error("Runtime health was not OK");
if (hello.kind !== "pi-agent-runtime") throw new Error("Unexpected Runtime hello kind");
if (hello.protocol?.major !== 1) throw new Error("Unexpected Runtime protocol major");
if (typeof hello.manifest?.piSdkVersion !== "string" || hello.manifest.piSdkVersion.length === 0) throw new Error("Bundled Pi SDK version is missing");
console.log(`Runtime smoke passed: ${hello.nodeVersion} ${hello.architecture}, epoch ${hello.runtimeEpoch}`);
' "$runtime_test_dir/health.json" "$runtime_test_dir/hello.json"

contract_binary="$(swift build --package-path "$repo_root/macos/PiAgent" --configuration debug --show-bin-path)/PiAgentContractCheck"
PI_AGENT_RUNTIME_SOCKET="$runtime_test_dir/sessiond.sock" \
PI_AGENT_PROJECT_PATH="$repo_root" \
"$contract_binary"
