import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import type { GitDiffResponse, GitFileState, GitPushPreview, GitRevertPreview, GitStatusFile, GitStatusResponse } from "../../shared/apiTypes.js";
import { normalizeRelativePath } from "../workspaces/pathSafety.js";
import { sanitizedGitEnv } from "./gitEnv.js";

const MAX_OUTPUT = 2 * 1024 * 1024;

/**
 * A submodule row parsed from the superproject status. `git status` reports a
 * submodule as a single path with an `S<c><m><u>` flag field (commit changed /
 * modified tracked content / untracked content) but never lists the files that
 * changed inside it, so we recurse in `expandSubmodules`.
 */
interface SubmoduleRecord {
  path: string;
  index: GitFileState;
  workingTree: GitFileState;
  commitChanged: boolean;
  hasModifiedContent: boolean;
  hasUntrackedContent: boolean;
  headOid: string;
  indexOid: string;
}

interface ParsedStatus {
  isGitRepo: true;
  branch?: string;
  upstream?: string;
  ahead?: number;
  behind?: number;
  files: GitStatusFile[];
  submodules: SubmoduleRecord[];
}

export async function gitStatus(cwd: string): Promise<GitStatusResponse> {
  const result = await runGit(cwd, ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"]);
  if (result.code !== 0) return { isGitRepo: false, hash: hash(result.stdout + result.stderr), files: [], submodules: [] };
  const parsed = parseStatus(result.stdout, { deferSubmodules: true });
  return expandSubmodules(cwd, parsed, result.stdout);
}

/**
 * Merge each dirty submodule's own changes into the flat file list. A moved
 * commit pointer becomes a single entry keyed by the submodule path (carrying
 * the short SHAs for display); modified/untracked content is listed as regular
 * entries under `<submodule>/<inner path>`. A plain `-dirty` pointer (commit
 * unchanged) is intentionally not surfaced as a pointer entry.
 */
async function expandSubmodules(cwd: string, parsed: ParsedStatus, topRaw: string): Promise<GitStatusResponse> {
  // Fan out concurrently — one `git status` per dirty submodule plus one
  // `git rev-parse` per unstaged pointer move — then concatenate in input
  // order so the file list and hash are identical to a serial pass.
  const expanded = await Promise.all(parsed.submodules.map(async (sub) => ({ path: sub.path, ...(await expandSubmodule(cwd, sub)) })));

  const files: GitStatusFile[] = [...parsed.files];
  const dirtySubmodulePaths: string[] = [];
  let extraForHash = "";
  for (const part of expanded) {
    dirtySubmodulePaths.push(part.path);
    files.push(...part.files);
    extraForHash += part.extraForHash;
  }

  return {
    isGitRepo: true,
    hash: hash(topRaw + extraForHash),
    ...(parsed.branch === undefined ? {} : { branch: parsed.branch }),
    ...(parsed.upstream === undefined ? {} : { upstream: parsed.upstream }),
    ...(parsed.ahead === undefined ? {} : { ahead: parsed.ahead }),
    ...(parsed.behind === undefined ? {} : { behind: parsed.behind }),
    files,
    submodules: dirtySubmodulePaths,
  };
}

/** Expand one dirty submodule: the pointer entry first, then its inner files. */
async function expandSubmodule(cwd: string, sub: SubmoduleRecord): Promise<{ files: GitStatusFile[]; extraForHash: string }> {
  const files: GitStatusFile[] = [];
  let extraForHash = "";
  if (sub.commitChanged) {
    files.push({
      path: sub.path,
      index: sub.index,
      workingTree: sub.workingTree,
      submoduleFromCommit: displayFromCommit(sub.headOid),
      submoduleToCommit: short(await resolveSubmoduleToCommit(cwd, sub)),
    });
  }
  if (sub.hasModifiedContent || sub.hasUntrackedContent) {
    const inner = await runGit(join(cwd, sub.path), ["status", "--porcelain=v2", "--untracked-files=all", "-z"]);
    if (inner.code === 0) {
      extraForHash = `\0${sub.path}\0${inner.stdout}`;
      const innerFiles = parseStatus(inner.stdout, { deferSubmodules: false }).files;
      for (const file of innerFiles) {
        files.push({
          ...file,
          path: `${sub.path}/${file.path}`,
          ...(file.oldPath === undefined ? {} : { oldPath: `${sub.path}/${file.oldPath}` }),
        });
      }
    }
    // non-zero exit: uninitialized / unreadable submodule — skip silently
  }
  return { files, extraForHash };
}

async function resolveSubmoduleToCommit(cwd: string, sub: SubmoduleRecord): Promise<string> {
  // Staged pointer moves already expose the new commit as the index OID; an
  // unstaged move only records the old OID, so read the submodule's HEAD.
  if (sub.indexOid !== sub.headOid) return sub.indexOid;
  const head = await runGit(join(cwd, sub.path), ["rev-parse", "HEAD"]);
  const resolved = head.stdout.trim();
  return head.code === 0 && resolved !== "" ? resolved : sub.indexOid;
}

export async function gitDiff(cwd: string, options: { path?: string; staged?: boolean }): Promise<GitDiffResponse> {
  const staged = options.staged === true;
  let path: string | undefined;
  if (options.path !== undefined && options.path !== "") path = normalizeRelativePath(options.path);

  if (path !== undefined) {
    const owner = await submoduleForPath(cwd, path);
    if (owner !== undefined) return submoduleDiff(cwd, owner, path, staged);
  }

  const args = ["diff", "--no-ext-diff", "--color=never"];
  if (staged) args.push("--cached");
  if (path !== undefined) args.push("--", path);

  const result = await runGit(cwd, args);
  if (result.code !== 0) throw new Error(result.stderr.trim() || "git diff failed");
  if (!staged && path !== undefined && result.stdout === "" && await isUntracked(cwd, path)) {
    const untracked = await runGit(cwd, ["diff", "--no-ext-diff", "--color=never", "--no-index", "/dev/null", "--", path]);
    if (untracked.code !== 0 && untracked.code !== 1) throw new Error(untracked.stderr.trim() || "git diff failed");
    return { path, staged, hash: hash(untracked.stdout), diff: untracked.stdout, truncated: untracked.truncated };
  }
  return { ...(path === undefined ? {} : { path }), staged, hash: hash(result.stdout), diff: result.stdout, truncated: result.truncated };
}

/** Stage the selected root-worktree paths. Git process ownership stays in the Runtime. */
export async function gitStage(cwd: string, paths: readonly string[]): Promise<GitStatusResponse> {
  const normalized = normalizeGitMutationPaths(paths);
	await requireRootWorktreePaths(cwd, normalized);
  await requireGitSuccess(cwd, ["add", "--", ...normalized], "git stage failed");
  return gitStatus(cwd);
}

/** Remove selected root-worktree paths from the index without touching their working-tree content. */
export async function gitUnstage(cwd: string, paths: readonly string[]): Promise<GitStatusResponse> {
  const normalized = normalizeGitMutationPaths(paths);
	await requireRootWorktreePaths(cwd, normalized);
  await requireGitSuccess(cwd, ["reset", "--mixed", "HEAD", "--", ...normalized], "git unstage failed");
  return gitStatus(cwd);
}

/**
 * Discard only already-tracked, unstaged root-worktree edits. It deliberately
 * excludes untracked files, index changes, renames, and submodules so this
 * narrow native action cannot turn into a destructive general Git shell.
 */
export async function gitDiscard(cwd: string, paths: readonly string[]): Promise<GitStatusResponse> {
	const normalized = normalizeGitMutationPaths(paths);
	await requireRootWorktreePaths(cwd, normalized);
	const status = await gitStatus(cwd);
	if (!status.isGitRepo) throw new Error("This project is not a Git repository.");
	for (const path of normalized) {
		const file = status.files.find((candidate) => candidate.path === path);
		if (file === undefined) {
			throw new Error(`Only a tracked, unstaged, non-renamed root-worktree change can be discarded: ${path}`);
		}
		if (
			file.index !== "unmodified" ||
			file.workingTree === "unmodified" ||
			file.workingTree === "untracked" ||
			file.oldPath !== undefined ||
			status.submodules.includes(path)
		) {
			throw new Error(`Only a tracked, unstaged, non-renamed root-worktree change can be discarded: ${path}`);
		}
	}
	await requireGitSuccess(cwd, ["restore", "--source=HEAD", "--worktree", "--", ...normalized], "git discard failed");
	return gitStatus(cwd);
}

export interface GitCommitResult {
  hash: string;
  subject: string;
  status: GitStatusResponse;
}

export interface GitRevertResult {
	hash: string;
	subject: string;
	status: GitStatusResponse;
}

/**
 * Returns an authoritative, read-only answer for the one push shape currently
 * supported by the native client: the active local branch to its configured
 * tracking upstream. This deliberately does not offer a remote, refspec,
 * force, tag, or set-upstream choice.
 */
export async function gitPushPreview(cwd: string): Promise<GitPushPreview> {
	const status = await gitStatus(cwd);
	if (!status.isGitRepo) return { status, canPush: false, reason: "This project is not a Git repository." };
	if (status.branch === undefined) return { status, canPush: false, reason: "Detached HEAD cannot be pushed from the native inspector." };
	if (status.upstream === undefined) return { status, canPush: false, reason: "The current branch has no configured tracking upstream." };
	if ((status.behind ?? 0) > 0) return { status, canPush: false, reason: "The upstream has commits that are not present locally. Pull or rebase before pushing." };
	if ((status.ahead ?? 0) < 1) return { status, canPush: false, reason: "There are no local commits waiting to be pushed." };
	return { status, canPush: true };
}

/**
 * Push only the current local branch to the exact tracking remote/ref. Both
 * arguments are derived by Git inside the Runtime after a fresh preview;
 * callers cannot select a remote or smuggle in force/refspec options.
 */
export async function gitPush(cwd: string): Promise<GitStatusResponse> {
	const preview = await gitPushPreview(cwd);
	if (!preview.canPush) throw new Error(preview.reason ?? "The current branch cannot be pushed.");
	const target = await trackingPushTarget(cwd, preview.status.branch ?? "");
	await requireGitSuccess(
		cwd,
		["push", "--porcelain", "--", target.remote, `${target.localRef}:${target.upstreamRef}`],
		"git push failed",
	);
	return gitStatus(cwd);
}

/** Read-only guard for the narrow, history-preserving latest-commit undo. */
export async function gitRevertPreview(cwd: string): Promise<GitRevertPreview> {
	const status = await gitStatus(cwd);
	if (!status.isGitRepo) return { status, canRevert: false, reason: "This project is not a Git repository." };
	if (status.files.length > 0) return { status, canRevert: false, reason: "Commit or clear all working-tree and index changes before undoing the latest commit." };
	const parents = await runGit(cwd, ["rev-list", "--parents", "-n", "1", "HEAD"]);
	if (parents.code !== 0 || parents.stdout.trim() === "") return { status, canRevert: false, reason: "This repository has no commit to undo." };
	const parts = parents.stdout.trim().split(/\s+/);
	if (parts.length !== 2) return { status, canRevert: false, reason: "Merge commits cannot be undone from the native inspector." };
	const subject = await runGit(cwd, ["show", "-s", "--format=%s", "HEAD"]);
	if (subject.code !== 0 || subject.stdout.trim() === "") return { status, canRevert: false, reason: subject.stderr.trim() || "Could not read the latest commit." };
	const [headHash] = parts;
	if (headHash === undefined) return { status, canRevert: false, reason: "Could not read the latest commit." };
	return { status, canRevert: true, commit: { hash: headHash, subject: subject.stdout.trim() } };
}

/** Create a new inverse commit for current non-merge HEAD. It never resets or force-pushes. */
export async function gitRevertHead(cwd: string): Promise<GitRevertResult> {
	const preview = await gitRevertPreview(cwd);
	if (!preview.canRevert || preview.commit === undefined) throw new Error(preview.reason ?? "The latest commit cannot be undone.");
	await requireGitSuccess(cwd, ["revert", "--no-edit", "HEAD"], "git revert failed");
	const head = await runGit(cwd, ["rev-parse", "HEAD"]);
	const subject = await runGit(cwd, ["show", "-s", "--format=%s", "HEAD"]);
	if (head.code !== 0 || head.stdout.trim() === "" || subject.code !== 0 || subject.stdout.trim() === "") {
		throw new Error(head.stderr.trim() || subject.stderr.trim() || "git revert did not produce a commit");
	}
	return { hash: head.stdout.trim(), subject: subject.stdout.trim(), status: await gitStatus(cwd) };
}

/** Commit the existing index only; callers must stage deliberately first. */
export async function gitCommit(cwd: string, message: string): Promise<GitCommitResult> {
  const normalized = normalizeCommitMessage(message);
  const subject = normalized.split(/\r?\n/, 1)[0] ?? normalized;
  await requireGitSuccess(cwd, ["commit", "-m", normalized], "git commit failed");
  const head = await runGit(cwd, ["rev-parse", "HEAD"]);
  if (head.code !== 0 || head.stdout.trim() === "") throw new Error(head.stderr.trim() || "git commit did not produce a commit hash");
  return { hash: head.stdout.trim(), subject, status: await gitStatus(cwd) };
}

export function normalizeGitMutationPaths(paths: readonly string[]): string[] {
  if (!Array.isArray(paths) || paths.length === 0) throw new Error("paths must contain at least one file");
  if (paths.length > 500) throw new Error("paths must contain at most 500 files");
  const normalized = paths.map((path) => {
    if (typeof path !== "string" || path.trim() === "") throw new Error("each Git path must be a non-empty string");
    return normalizeRelativePath(path);
  });
  return [...new Set(normalized)].sort();
}

export function normalizeCommitMessage(message: string): string {
  if (typeof message !== "string") throw new Error("message must be a string");
  const normalized = message.trim();
  if (normalized === "") throw new Error("Commit message is required");
  if (normalized.length > 4_000) throw new Error("Commit message must be at most 4000 characters");
  return normalized;
}

async function requireGitSuccess(cwd: string, args: string[], fallback: string): Promise<void> {
  const result = await runGit(cwd, args);
  if (result.code !== 0) throw new Error(result.stderr.trim() || fallback);
}

async function trackingPushTarget(cwd: string, branch: string): Promise<{ remote: string; localRef: string; upstreamRef: string }> {
	if (branch === "" || branch.includes("\0") || branch.includes("\n")) {
		throw new Error("The current branch name is not safe to push.");
	}
	const localRef = `refs/heads/${branch}`;
	const result = await runGit(cwd, [
		"for-each-ref",
		"--format=%(upstream:remotename)%00%(upstream:remoteref)",
		localRef,
	]);
	if (result.code !== 0) throw new Error(result.stderr.trim() || "Could not resolve the tracking upstream.");
	const [remote = "", upstreamRef = ""] = result.stdout.trimEnd().split("\0");
	if (
		remote === "" || upstreamRef === "" || remote.includes("\n") || remote.includes("\0") ||
		upstreamRef.includes("\n") || upstreamRef.includes("\0") || !upstreamRef.startsWith("refs/heads/")
	) {
		throw new Error("The current branch does not have a pushable tracking upstream.");
	}
	return { remote, localRef, upstreamRef };
}

async function requireRootWorktreePaths(cwd: string, paths: readonly string[]): Promise<void> {
	for (const path of paths) {
		if (await submoduleForPath(cwd, path) !== undefined) {
			throw new Error("Staging files inside a submodule is not available in the native inspector yet. Stage the submodule in its own checkout first.");
		}
	}
}

/**
 * Run the diff inside the owning submodule's working tree, since `git diff` at
 * the superproject root never shows content changes below a submodule boundary.
 * The response path stays the full superproject-relative path so the viewer and
 * the selected row line up.
 */
async function submoduleDiff(cwd: string, owner: string, path: string, staged: boolean): Promise<GitDiffResponse> {
  const subCwd = join(cwd, owner);
  const rel = normalizeRelativePath(path.slice(owner.length + 1));

  const args = ["diff", "--no-ext-diff", "--color=never"];
  if (staged) args.push("--cached");
  args.push("--", rel);

  const result = await runGit(subCwd, args);
  if (result.code !== 0) throw new Error(result.stderr.trim() || "git diff failed");
  if (!staged && result.stdout === "" && await isUntracked(subCwd, rel)) {
    const untracked = await runGit(subCwd, ["diff", "--no-ext-diff", "--color=never", "--no-index", "/dev/null", "--", rel]);
    if (untracked.code !== 0 && untracked.code !== 1) throw new Error(untracked.stderr.trim() || "git diff failed");
    return { path, staged, hash: hash(untracked.stdout), diff: untracked.stdout, truncated: untracked.truncated };
  }
  return { path, staged, hash: hash(result.stdout), diff: result.stdout, truncated: result.truncated };
}

async function isUntracked(cwd: string, path: string): Promise<boolean> {
  const result = await runGit(cwd, ["ls-files", "--others", "--exclude-standard", "-z", "--", path]);
  return result.code === 0 && result.stdout.split("\0").includes(path);
}

/** Configured direct-submodule paths (depth 1), read from `.gitmodules`. */
async function configuredSubmodulePaths(cwd: string): Promise<string[]> {
  // `-z` emits `<key>\n<value>\0` records; keys may themselves contain spaces
  // (`submodule.my sub.path`), so splitting lines at the first space mangles
  // paths with spaces in them.
  const result = await runGit(cwd, ["config", "-z", "--file", ".gitmodules", "--get-regexp", "^submodule\\..+\\.path$"]);
  if (result.code !== 0) return [];
  const paths: string[] = [];
  for (const record of result.stdout.split("\0")) {
    if (record === "") continue;
    const newlineAt = record.indexOf("\n");
    if (newlineAt === -1) continue;
    paths.push(record.slice(newlineAt + 1));
  }
  return paths;
}

/** The submodule that strictly contains `path`, if any (longest match wins). */
async function submoduleForPath(cwd: string, path: string): Promise<string | undefined> {
  // Cheap bail-outs before spawning `git config`: a path strictly inside a
  // submodule always contains `/`, and without `.gitmodules` there are no
  // configured submodules to look up (every diff call used to pay this spawn).
  if (!path.includes("/")) return undefined;
  if (!existsSync(join(cwd, ".gitmodules"))) return undefined;
  const subs = await configuredSubmodulePaths(cwd);
  let best: string | undefined;
  for (const sub of subs) {
    if (sub !== "" && path.startsWith(`${sub}/`) && (best === undefined || sub.length > best.length)) best = sub;
  }
  return best;
}

function parseStatus(raw: string, options: { deferSubmodules: boolean }): ParsedStatus {
  const records = raw.split("\0").filter((record) => record !== "");
  const files: GitStatusFile[] = [];
  const submodules: SubmoduleRecord[] = [];
  let branch: string | undefined;
  let upstream: string | undefined;
  let ahead: number | undefined;
  let behind: number | undefined;

  for (let i = 0; i < records.length; i += 1) {
    const record = records[i];
    if (record === undefined) continue;
    if (record.startsWith("# branch.head ")) branch = normalizeBranch(record.slice("# branch.head ".length));
    else if (record.startsWith("# branch.upstream ")) upstream = record.slice("# branch.upstream ".length);
    else if (record.startsWith("# branch.ab ")) {
      const match = /\+(\d+) -(\d+)/.exec(record);
      if (match) { ahead = Number(match[1]); behind = Number(match[2]); }
    } else if (record.startsWith("? ")) files.push({ path: record.slice(2), index: "untracked", workingTree: "untracked" });
    else if (record.startsWith("! ")) files.push({ path: record.slice(2), index: "ignored", workingTree: "ignored" });
    else if (record.startsWith("1 ")) {
      const parts = record.split(" ");
      const sub = parts[2];
      const path = parts.slice(8).join(" ");
      const index = stateFor(parts[1]?.[0]);
      const workingTree = stateFor(parts[1]?.[1]);
      // A deleted gitlink has no pointer move or inner content to expand (a
      // staged deletion even reports the index OID as all zeros), so keep it
      // as a plain row instead of deferring it as a submodule.
      if (options.deferSubmodules && sub?.startsWith("S") === true && index !== "deleted" && workingTree !== "deleted") {
        const headOid = parts[6] ?? "";
        const indexOid = parts[7] ?? "";
        submodules.push({
          path,
          index,
          workingTree,
          // `c` only flags unstaged moves (submodule HEAD left the index OID);
          // a staged move leaves HEAD == index, so compare the recorded OIDs.
          commitChanged: sub[1] === "C" || headOid !== indexOid,
          hasModifiedContent: sub[2] === "M",
          hasUntrackedContent: sub[3] === "U",
          headOid,
          indexOid,
        });
      } else {
        files.push({ path, index, workingTree });
      }
    } else if (record.startsWith("2 ")) {
      const parts = record.split(" ");
      const path = parts.slice(9).join(" ");
      const oldPath = records[i + 1];
      i += 1;
      files.push({ path, ...(oldPath === undefined ? {} : { oldPath }), index: stateFor(parts[1]?.[0]), workingTree: stateFor(parts[1]?.[1]) });
    } else if (record.startsWith("u ")) {
      const parts = record.split(" ");
      files.push({ path: parts.slice(10).join(" "), index: "conflicted", workingTree: "conflicted" });
    }
  }

  return { isGitRepo: true, ...(branch === undefined ? {} : { branch }), ...(upstream === undefined ? {} : { upstream }), ...(ahead === undefined ? {} : { ahead }), ...(behind === undefined ? {} : { behind }), files, submodules };
}

function stateFor(code: string | undefined): GitFileState {
  if (code === undefined) return "unmodified";
  switch (code) {
    case ".": return "unmodified";
    case "M": return "modified";
    case "A": return "added";
    case "D": return "deleted";
    case "R": return "renamed";
    case "C": return "copied";
    case "U": return "conflicted";
    default: return "unmodified";
  }
}

function normalizeBranch(value: string): string | undefined {
  return value === "(detached)" ? undefined : value;
}

function short(oid: string): string {
  return oid.slice(0, 7);
}

/** A newly staged submodule records an all-zero head OID; display the pointer as `new → <sha>`. */
function displayFromCommit(headOid: string): string {
  return /^0+$/.test(headOid) ? "new" : short(headOid);
}

function hash(value: string): string {
  return createHash("sha1").update(value).digest("hex");
}

async function runGit(cwd: string, args: string[]): Promise<{ code: number; stdout: string; stderr: string; truncated: boolean }> {
  return new Promise((resolve, reject) => {
    const child = spawn("git", args, { cwd, env: sanitizedGitEnv(), stdio: ["ignore", "pipe", "pipe"] });
    const timer = setTimeout(() => { child.kill("SIGKILL"); }, 10000);
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let truncated = false;
    child.stdout.on("data", (chunk: Buffer) => {
      if (stdout.length + chunk.length > MAX_OUTPUT) truncated = true;
      if (stdout.length < MAX_OUTPUT) stdout = Buffer.concat([stdout, chunk]).subarray(0, MAX_OUTPUT);
    });
    child.stderr.on("data", (chunk: Buffer) => { stderr = Buffer.concat([stderr, chunk]).subarray(0, 64 * 1024); });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code) => { clearTimeout(timer); resolve({ code: code ?? 1, stdout: stdout.toString("utf8"), stderr: stderr.toString("utf8"), truncated }); });
  });
}
