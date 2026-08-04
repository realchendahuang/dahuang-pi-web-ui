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
project_capability_token="$(uuidgen | tr '[:upper:]' '[:lower:]')"

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
PI_AGENT_RUNTIME_PROJECT_CAPABILITY_TOKEN="$project_capability_token" \
"$node_path" "$launcher_path" >"$runtime_test_dir/runtime.log" 2>&1 &
runtime_pid=$!

for attempt in $(seq 1 240); do
  if curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" http://pi-agent/health >"$runtime_test_dir/health.json"; then
    break
  fi
  sleep 0.125
  if [[ "$attempt" == "240" ]]; then
    cat "$runtime_test_dir/runtime.log"
    exit 1
  fi
done

curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" http://pi-agent/runtime/hello >"$runtime_test_dir/hello.json"
runtime_epoch="$("$node_path" --input-type=module -e '
import { readFile } from "node:fs/promises";
const hello = JSON.parse(await readFile(process.argv[1], "utf8"));
if (typeof hello.runtimeEpoch !== "string" || hello.runtimeEpoch.length === 0) throw new Error("Runtime hello did not include an epoch");
process.stdout.write(hello.runtimeEpoch);
' "$runtime_test_dir/hello.json")"
unauthorized_status="$(curl --silent --output "$runtime_test_dir/unauthorized.json" --write-out '%{http_code}' --get --data-urlencode "cwd=$repo_root" --unix-socket "$runtime_test_dir/sessiond.sock" http://pi-agent/sessions)"
test "$unauthorized_status" = "401"
unapproved_status="$(curl --silent --output "$runtime_test_dir/unapproved.json" --write-out '%{http_code}' --get --data-urlencode "cwd=$repo_root" --unix-socket "$runtime_test_dir/sessiond.sock" -H "X-Pi-Agent-Project-Capability: $project_capability_token" http://pi-agent/sessions)"
test "$unapproved_status" = "403"
authorize_command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
authorize_payload="$("$node_path" --input-type=module -e 'process.stdout.write(JSON.stringify({ path: process.argv[1], commandId: process.argv[2], runtimeEpoch: process.argv[3] }))' "$repo_root" "$authorize_command_id" "$runtime_epoch")"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$authorize_payload" \
  http://pi-agent/runtime/projects/authorize >"$runtime_test_dir/authorize-receipt.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --get --data-urlencode "cwd=$repo_root" \
  http://pi-agent/sessions >"$runtime_test_dir/sessions.json"
command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "{\"commandId\":\"$command_id\",\"runtimeEpoch\":\"$runtime_epoch\"}" \
  http://pi-agent/runtime/commands/abort-active-work >"$runtime_test_dir/abort-receipt.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  "http://pi-agent/runtime/commands/$command_id" >"$runtime_test_dir/abort-receipt-retry.json"
test "$(stat -f '%Lp' "$runtime_test_dir")" = "700"
test "$(stat -f '%Lp' "$runtime_test_dir/sessiond.sock")" = "600"
"$node_path" --input-type=module -e '
import { readFile } from "node:fs/promises";
const [healthPath, helloPath, authorizePath, receiptPath, retryPath] = process.argv.slice(1);
const health = JSON.parse(await readFile(healthPath, "utf8"));
const hello = JSON.parse(await readFile(helloPath, "utf8"));
const authorized = JSON.parse(await readFile(authorizePath, "utf8"));
const receipt = JSON.parse(await readFile(receiptPath, "utf8"));
const retry = JSON.parse(await readFile(retryPath, "utf8"));
if (health.ok !== true) throw new Error("Runtime health was not OK");
if (hello.kind !== "pi-agent-runtime") throw new Error("Unexpected Runtime hello kind");
if (hello.protocol?.major !== 1) throw new Error("Unexpected Runtime protocol major");
if (typeof hello.manifest?.piSdkVersion !== "string" || hello.manifest.piSdkVersion.length === 0) throw new Error("Bundled Pi SDK version is missing");
if (authorized.kind !== "authorize-project" || authorized.status !== "completed" || authorized.result?.authorized !== true) throw new Error("Runtime project authorization did not complete");
if (receipt.kind !== "abort-active-work" || receipt.status !== "completed") throw new Error("Runtime abort receipt did not complete");
if (receipt.runtimeEpoch !== hello.runtimeEpoch) throw new Error("Runtime abort receipt epoch did not match hello");
if (receipt.result?.requested !== 0 || receipt.result?.failures?.length !== 0) throw new Error("Idle Runtime abort receipt was unexpected");
if (retry.commandId !== receipt.commandId || retry.status !== receipt.status) throw new Error("Runtime receipt retry was not idempotent");
console.log(`Runtime smoke passed: ${hello.nodeVersion} ${hello.architecture}, epoch ${hello.runtimeEpoch}`);
' "$runtime_test_dir/health.json" "$runtime_test_dir/hello.json" "$runtime_test_dir/authorize-receipt.json" "$runtime_test_dir/abort-receipt.json" "$runtime_test_dir/abort-receipt-retry.json"

contract_binary="$(swift build --package-path "$repo_root/macos/PiAgent" --configuration debug --show-bin-path)/PiAgentContractCheck"
PI_AGENT_RUNTIME_SOCKET="$runtime_test_dir/sessiond.sock" \
PI_AGENT_RUNTIME_PROJECT_CAPABILITY_TOKEN="$project_capability_token" \
PI_AGENT_PROJECT_PATH="$repo_root" \
"$contract_binary"
