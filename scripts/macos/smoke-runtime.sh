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
workspace_project_dir="$runtime_test_dir/workspace-project"
runtime_pid=""
project_capability_token="$(uuidgen | tr '[:upper:]' '[:lower:]')"

mkdir -p "$workspace_project_dir"
printf 'seed file\n' >"$workspace_project_dir/seed.txt"
# Tiny PNG signature fixture: it verifies the Native Contract returns image
# bytes from an authorized workspace without granting the Swift client a path.
printf '\211PNG\r\n\032\n\000' >"$workspace_project_dir/preview.png"

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
unauthorized_workspace_status="$(curl --silent --output "$runtime_test_dir/unauthorized-workspace.json" --write-out '%{http_code}' --get --data-urlencode "cwd=$repo_root" --unix-socket "$runtime_test_dir/sessiond.sock" http://pi-agent/workspace/tree)"
test "$unauthorized_workspace_status" = "401"
unapproved_status="$(curl --silent --output "$runtime_test_dir/unapproved.json" --write-out '%{http_code}' --get --data-urlencode "cwd=$repo_root" --unix-socket "$runtime_test_dir/sessiond.sock" -H "X-Pi-Agent-Project-Capability: $project_capability_token" http://pi-agent/sessions)"
test "$unapproved_status" = "403"
unapproved_workspace_status="$(curl --silent --output "$runtime_test_dir/unapproved-workspace.json" --write-out '%{http_code}' --get --data-urlencode "cwd=$repo_root" --unix-socket "$runtime_test_dir/sessiond.sock" -H "X-Pi-Agent-Project-Capability: $project_capability_token" http://pi-agent/workspace/tree)"
test "$unapproved_workspace_status" = "403"
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
checkpoint_command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
checkpoint_payload="$("$node_path" --input-type=module -e 'process.stdout.write(JSON.stringify({ cwd: process.argv[1], sessionId: "runtime-smoke-thread", commandId: process.argv[2], runtimeEpoch: process.argv[3] }))' "$repo_root" "$checkpoint_command_id" "$runtime_epoch")"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$checkpoint_payload" \
  http://pi-agent/git/checkpoints >"$runtime_test_dir/checkpoint-receipt.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$checkpoint_payload" \
  http://pi-agent/git/checkpoints >"$runtime_test_dir/checkpoint-retry.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --get --data-urlencode "cwd=$repo_root" --data-urlencode "sessionId=runtime-smoke-thread" \
  http://pi-agent/git/checkpoints >"$runtime_test_dir/checkpoints.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --get --data-urlencode "cwd=$repo_root" \
  http://pi-agent/workspace/tree >"$runtime_test_dir/workspace-tree.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --get --data-urlencode "cwd=$repo_root" --data-urlencode "path=package.json" \
  http://pi-agent/workspace/file >"$runtime_test_dir/workspace-file.json"
workspace_authorize_command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
workspace_authorize_payload="$("$node_path" --input-type=module -e 'process.stdout.write(JSON.stringify({ path: process.argv[1], commandId: process.argv[2], runtimeEpoch: process.argv[3] }))' "$workspace_project_dir" "$workspace_authorize_command_id" "$runtime_epoch")"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$workspace_authorize_payload" \
  http://pi-agent/runtime/projects/authorize >"$runtime_test_dir/workspace-authorize-receipt.json"
workspace_write_command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
workspace_write_payload="$("$node_path" --input-type=module -e 'process.stdout.write(JSON.stringify({ cwd: process.argv[1], path: "Notes/agent.txt", content: "native edit\\n", overwrite: false, commandId: process.argv[2], runtimeEpoch: process.argv[3] }))' "$workspace_project_dir" "$workspace_write_command_id" "$runtime_epoch")"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -X PUT -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$workspace_write_payload" \
  http://pi-agent/workspace/file >"$runtime_test_dir/workspace-write-receipt.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -X PUT -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$workspace_write_payload" \
  http://pi-agent/workspace/file >"$runtime_test_dir/workspace-write-retry.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --get --data-urlencode "cwd=$workspace_project_dir" --data-urlencode "path=Notes/agent.txt" \
  http://pi-agent/workspace/file >"$runtime_test_dir/workspace-written-file.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --get --data-urlencode "cwd=$workspace_project_dir" --data-urlencode "path=preview.png" \
  http://pi-agent/workspace/file/preview >"$runtime_test_dir/workspace-image-preview.json"
workspace_move_command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
workspace_move_payload="$("$node_path" --input-type=module -e 'process.stdout.write(JSON.stringify({ cwd: process.argv[1], fromPath: "Notes/agent.txt", toPath: "Notes/renamed.txt", overwrite: false, commandId: process.argv[2], runtimeEpoch: process.argv[3] }))' "$workspace_project_dir" "$workspace_move_command_id" "$runtime_epoch")"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$workspace_move_payload" \
  http://pi-agent/workspace/file/move >"$runtime_test_dir/workspace-move-receipt.json"
workspace_delete_command_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
workspace_delete_payload="$("$node_path" --input-type=module -e 'process.stdout.write(JSON.stringify({ cwd: process.argv[1], path: "Notes/renamed.txt", commandId: process.argv[2], runtimeEpoch: process.argv[3] }))' "$workspace_project_dir" "$workspace_delete_command_id" "$runtime_epoch")"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -X DELETE -H 'content-type: application/json' \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  --data "$workspace_delete_payload" \
  http://pi-agent/workspace/file >"$runtime_test_dir/workspace-delete-receipt.json"
curl --silent --fail --unix-socket "$runtime_test_dir/sessiond.sock" \
  -H "X-Pi-Agent-Project-Capability: $project_capability_token" \
  "http://pi-agent/runtime/commands/$workspace_write_command_id" >"$runtime_test_dir/workspace-write-retry-query.json"
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
const [healthPath, helloPath, authorizePath, receiptPath, retryPath, treePath, checkpointReceiptPath, checkpointRetryPath, checkpointsPath, filePath, workspaceAuthorizePath, workspaceWritePath, workspaceWriteRetryPath, workspaceWrittenFilePath, workspaceImagePreviewPath, workspaceMovePath, workspaceDeletePath, workspaceWriteQueryPath] = process.argv.slice(1);
const health = JSON.parse(await readFile(healthPath, "utf8"));
const hello = JSON.parse(await readFile(helloPath, "utf8"));
const authorized = JSON.parse(await readFile(authorizePath, "utf8"));
const receipt = JSON.parse(await readFile(receiptPath, "utf8"));
const retry = JSON.parse(await readFile(retryPath, "utf8"));
const tree = JSON.parse(await readFile(treePath, "utf8"));
const checkpointReceipt = JSON.parse(await readFile(checkpointReceiptPath, "utf8"));
const checkpointRetry = JSON.parse(await readFile(checkpointRetryPath, "utf8"));
const checkpoints = JSON.parse(await readFile(checkpointsPath, "utf8"));
const file = JSON.parse(await readFile(filePath, "utf8"));
const workspaceAuthorized = JSON.parse(await readFile(workspaceAuthorizePath, "utf8"));
const workspaceWrite = JSON.parse(await readFile(workspaceWritePath, "utf8"));
const workspaceWriteRetry = JSON.parse(await readFile(workspaceWriteRetryPath, "utf8"));
const workspaceWrittenFile = JSON.parse(await readFile(workspaceWrittenFilePath, "utf8"));
const workspaceImagePreview = JSON.parse(await readFile(workspaceImagePreviewPath, "utf8"));
const workspaceMove = JSON.parse(await readFile(workspaceMovePath, "utf8"));
const workspaceDelete = JSON.parse(await readFile(workspaceDeletePath, "utf8"));
const workspaceWriteQuery = JSON.parse(await readFile(workspaceWriteQueryPath, "utf8"));
if (health.ok !== true) throw new Error("Runtime health was not OK");
if (hello.kind !== "pi-agent-runtime") throw new Error("Unexpected Runtime hello kind");
if (hello.protocol?.major !== 1) throw new Error("Unexpected Runtime protocol major");
if (typeof hello.manifest?.piSdkVersion !== "string" || hello.manifest.piSdkVersion.length === 0) throw new Error("Bundled Pi SDK version is missing");
if (authorized.kind !== "authorize-project" || authorized.status !== "completed" || authorized.result?.authorized !== true) throw new Error("Runtime project authorization did not complete");
if (receipt.kind !== "abort-active-work" || receipt.status !== "completed") throw new Error("Runtime abort receipt did not complete");
if (receipt.runtimeEpoch !== hello.runtimeEpoch) throw new Error("Runtime abort receipt epoch did not match hello");
if (receipt.result?.requested !== 0 || receipt.result?.failures?.length !== 0) throw new Error("Idle Runtime abort receipt was unexpected");
if (retry.commandId !== receipt.commandId || retry.status !== receipt.status) throw new Error("Runtime receipt retry was not idempotent");
if (checkpointReceipt.kind !== "create-git-checkpoint" || checkpointReceipt.status !== "completed" || checkpointReceipt.result?.checkpointed !== true) throw new Error("Runtime Git checkpoint did not complete");
if (JSON.stringify(checkpointRetry) !== JSON.stringify(checkpointReceipt) || !Array.isArray(checkpoints) || checkpoints[0]?.id !== checkpointReceipt.result?.checkpoint?.id) throw new Error("Runtime Git checkpoint was not receipt-safe or listable");
if (tree.path !== "" || !Array.isArray(tree.entries) || !tree.entries.some((entry) => entry.path === "package.json")) throw new Error("Runtime workspace tree did not project package.json");
if (tree.entries.some((entry) => typeof entry.path !== "string" || entry.path.startsWith("/"))) throw new Error("Runtime workspace tree exposed an absolute child path");
if (file.path !== "package.json" || file.binary !== false || typeof file.content !== "string") throw new Error("Runtime workspace file projection was invalid");
if (workspaceAuthorized.kind !== "authorize-project" || workspaceAuthorized.status !== "completed") throw new Error("Temporary workspace project authorization did not complete");
if (workspaceWrite.kind !== "write-workspace-file" || workspaceWrite.status !== "completed" || workspaceWrite.result?.written !== true || workspaceWrite.result?.created !== true) throw new Error("Runtime workspace write did not complete");
if (JSON.stringify(workspaceWriteRetry) !== JSON.stringify(workspaceWrite) || workspaceWriteQuery.commandId !== workspaceWrite.commandId) throw new Error("Runtime workspace write receipt was not idempotent");
if (workspaceWrittenFile.path !== "Notes/agent.txt" || workspaceWrittenFile.content !== "native edit\\n") throw new Error("Runtime workspace write did not persist the text file");
if (workspaceImagePreview.path !== "preview.png" || workspaceImagePreview.mimeType !== "image/png" || workspaceImagePreview.size !== 9) throw new Error("Runtime workspace image preview metadata was invalid");
if (!Buffer.from(workspaceImagePreview.data, "base64").equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]))) throw new Error("Runtime workspace image preview bytes were invalid");
if (workspaceMove.kind !== "move-workspace-file" || workspaceMove.status !== "completed" || workspaceMove.result?.toPath !== "Notes/renamed.txt") throw new Error("Runtime workspace move did not complete");
if (workspaceDelete.kind !== "delete-workspace-file" || workspaceDelete.status !== "completed" || workspaceDelete.result?.existed !== true) throw new Error("Runtime workspace delete did not complete");
console.log(`Runtime smoke passed: ${hello.nodeVersion} ${hello.architecture}, epoch ${hello.runtimeEpoch}`);
' "$runtime_test_dir/health.json" "$runtime_test_dir/hello.json" "$runtime_test_dir/authorize-receipt.json" "$runtime_test_dir/abort-receipt.json" "$runtime_test_dir/abort-receipt-retry.json" "$runtime_test_dir/workspace-tree.json" "$runtime_test_dir/checkpoint-receipt.json" "$runtime_test_dir/checkpoint-retry.json" "$runtime_test_dir/checkpoints.json" "$runtime_test_dir/workspace-file.json" "$runtime_test_dir/workspace-authorize-receipt.json" "$runtime_test_dir/workspace-write-receipt.json" "$runtime_test_dir/workspace-write-retry.json" "$runtime_test_dir/workspace-written-file.json" "$runtime_test_dir/workspace-image-preview.json" "$runtime_test_dir/workspace-move-receipt.json" "$runtime_test_dir/workspace-delete-receipt.json" "$runtime_test_dir/workspace-write-retry-query.json"

contract_binary="$(swift build --package-path "$repo_root/macos/PiAgent" --configuration debug --show-bin-path)/PiAgentContractCheck"
PI_AGENT_RUNTIME_SOCKET="$runtime_test_dir/sessiond.sock" \
PI_AGENT_RUNTIME_PROJECT_CAPABILITY_TOKEN="$project_capability_token" \
PI_AGENT_PROJECT_PATH="$repo_root" \
"$contract_binary"
