import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { gitCommit, gitDiscard, gitDiff, gitPush, gitPushPreview, gitRevertHead, gitRevertPreview, gitStage, gitStatus, gitUnstage } from "./gitService.js";

// Isolate from any global/system git config and force a deterministic identity;
// `protocol.file.allow` is required for `submodule add` from a local path.
const GIT_FLAGS = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "protocol.file.allow=always", "-c", "commit.gpgsign=false"];
// Strip all GIT_* variables (e.g. GIT_DIR/GIT_INDEX_FILE, set by git hooks such
// as this repo's pre-commit verify run) so fixture commands never pick up an
// outer repository's environment, then pin the handful we rely on.
const GIT_ENV = Object.fromEntries([
  ...Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_")),
  ["GIT_CONFIG_GLOBAL", "/dev/null"],
  ["GIT_CONFIG_SYSTEM", "/dev/null"],
  ["GIT_TERMINAL_PROMPT", "0"],
]);

const created: string[] = [];
afterAll(() => { for (const dir of created) rmSync(dir, { recursive: true, force: true }); });

function git(cwd: string, args: string[]): string {
  return execFileSync("git", [...GIT_FLAGS, ...args], { cwd, encoding: "utf8", env: GIT_ENV });
}

/** Superproject at `dir` with a submodule `HARL` recorded at commit `c2`; the
 * submodule origin has two commits `c1` (a.txt=v1) then `c2` (a.txt=v2). */
function createFixture(): { dir: string; c1: string; c2: string } {
  const base = mkdtempSync(join(tmpdir(), "pi-web-sub-"));
  created.push(base);
  const origin = join(base, "origin");
  const sup = join(base, "sup");

  git(base, ["init", "-b", "main", origin]);
  writeFileSync(join(origin, "a.txt"), "v1\n");
  git(origin, ["add", "-A"]);
  git(origin, ["commit", "-m", "c1"]);
  const c1 = git(origin, ["rev-parse", "HEAD"]).trim();
  writeFileSync(join(origin, "a.txt"), "v2\n");
  git(origin, ["add", "-A"]);
  git(origin, ["commit", "-m", "c2"]);
  const c2 = git(origin, ["rev-parse", "HEAD"]).trim();

  git(base, ["init", "-b", "main", sup]);
  git(sup, ["submodule", "add", origin, "HARL"]);
  writeFileSync(join(sup, "root.txt"), "root\n");
  git(sup, ["add", "-A"]);
  git(sup, ["commit", "-m", "init"]);
  return { dir: sup, c1, c2 };
}

/** Superproject at `dir` whose only submodule lives at the spaced path
 * `my sub`; the submodule origin has a single commit (a.txt=v1). */
function createSpacedPathFixture(): { dir: string } {
  const base = mkdtempSync(join(tmpdir(), "pi-web-sub-space-"));
  created.push(base);
  const origin = join(base, "origin");
  const sup = join(base, "sup");

  git(base, ["init", "-b", "main", origin]);
  writeFileSync(join(origin, "a.txt"), "v1\n");
  git(origin, ["add", "-A"]);
  git(origin, ["commit", "-m", "c1"]);

  git(base, ["init", "-b", "main", sup]);
  git(sup, ["submodule", "add", origin, "my sub"]);
  writeFileSync(join(sup, "root.txt"), "root\n");
  git(sup, ["add", "-A"]);
  git(sup, ["commit", "-m", "init"]);
  return { dir: sup };
}

describe("gitStatus with submodules", () => {
  it("surfaces a moved commit pointer with short SHAs and no inner files", async () => {
    const { dir, c1, c2 } = createFixture();
    git(join(dir, "HARL"), ["checkout", c1]); // move the pointer, leave the tree clean

    const status = await gitStatus(dir);
    expect(status.submodules).toContain("HARL");
    const pointer = status.files.find((file) => file.path === "HARL");
    expect(pointer?.submoduleFromCommit).toBe(c2.slice(0, 7));
    expect(pointer?.submoduleToCommit).toBe(c1.slice(0, 7));
    expect(status.files.some((file) => file.path.startsWith("HARL/"))).toBe(false);
  });

  it("lists modified and untracked inner files and omits the pointer when the commit is unchanged", async () => {
    const { dir } = createFixture();
    writeFileSync(join(dir, "HARL", "a.txt"), "v2\nchanged\n");
    writeFileSync(join(dir, "HARL", "new.txt"), "brand-new\n");

    const status = await gitStatus(dir);
    expect(status.submodules).toContain("HARL");
    expect(status.files.find((file) => file.path === "HARL")).toBeUndefined();
    const inner = status.files.filter((file) => file.path.startsWith("HARL/")).map((file) => file.path);
    expect(inner).toContain("HARL/a.txt");
    expect(inner).toContain("HARL/new.txt");
  });

  it("surfaces a staged pointer move with the recorded OID as from and the staged OID as to", async () => {
    const { dir, c1, c2 } = createFixture();
    git(join(dir, "HARL"), ["checkout", c1]); // move the pointer
    git(dir, ["add", "HARL"]); // stage the move: porcelain `1 M. S... <c2> <c1> HARL`

    const status = await gitStatus(dir);
    expect(status.submodules).toContain("HARL");
    const pointer = status.files.find((file) => file.path === "HARL");
    expect(pointer?.index).toBe("modified");
    expect(pointer?.workingTree).toBe("unmodified");
    expect(pointer?.submoduleFromCommit).toBe(c2.slice(0, 7));
    expect(pointer?.submoduleToCommit).toBe(c1.slice(0, 7));
  });

  it("reports both the pointer entry and inner files for a staged move with dirty content", async () => {
    const { dir, c1, c2 } = createFixture();
    git(join(dir, "HARL"), ["checkout", c1]);
    git(dir, ["add", "HARL"]);
    writeFileSync(join(dir, "HARL", "a.txt"), "v1\ndirty\n"); // combined `1 MM S.M.`

    const status = await gitStatus(dir);
    const pointer = status.files.find((file) => file.path === "HARL");
    expect(pointer?.index).toBe("modified");
    expect(pointer?.workingTree).toBe("modified");
    expect(pointer?.submoduleFromCommit).toBe(c2.slice(0, 7));
    expect(pointer?.submoduleToCommit).toBe(c1.slice(0, 7));
    const inner = status.files.find((file) => file.path === "HARL/a.txt");
    expect(inner?.workingTree).toBe("modified");
  });

  it("reports a deleted submodule as a plain deleted row", async () => {
    const { dir } = createFixture();
    rmSync(join(dir, "HARL"), { recursive: true, force: true }); // unstaged deletion: `1 .D S...`

    const status = await gitStatus(dir);
    const row = status.files.find((file) => file.path === "HARL");
    expect(row?.workingTree).toBe("deleted");
    expect(row?.submoduleFromCommit).toBeUndefined();
    expect(status.submodules).not.toContain("HARL");
    expect(status.files.some((file) => file.path.startsWith("HARL/"))).toBe(false);
  });

  it("reports a staged submodule deletion as a plain deleted row, not a pointer move", async () => {
    const { dir } = createFixture();
    git(dir, ["rm", "-q", "HARL"]); // staged deletion: `1 D. S...` with a zero index OID

    const status = await gitStatus(dir);
    const row = status.files.find((file) => file.path === "HARL");
    expect(row?.index).toBe("deleted");
    expect(row?.submoduleFromCommit).toBeUndefined();
    expect(status.submodules).not.toContain("HARL");
  });

  it("renders a newly staged submodule pointer as new → <sha> (zero head OID)", async () => {
    const { dir, c2 } = createFixture();
    git(dir, ["submodule", "add", join(dir, "..", "origin"), "NEWSUB"]); // staged add: `1 A. S...` with a zero head OID

    const status = await gitStatus(dir);
    const pointer = status.files.find((file) => file.path === "NEWSUB");
    expect(pointer?.index).toBe("added");
    expect(pointer?.submoduleFromCommit).toBe("new");
    expect(pointer?.submoduleToCommit).toBe(c2.slice(0, 7));
    expect(status.submodules).toContain("NEWSUB");
  });

  it("prefixes oldPath with the submodule path for renames inside a submodule", async () => {
    const { dir } = createFixture();
    git(join(dir, "HARL"), ["mv", "a.txt", "renamed.txt"]);

    const status = await gitStatus(dir);
    const renamed = status.files.find((file) => file.path === "HARL/renamed.txt");
    expect(renamed?.index).toBe("renamed");
    expect(renamed?.oldPath).toBe("HARL/a.txt");
  });

  it("keeps inner filenames with spaces intact through expansion", async () => {
    const { dir } = createFixture();
    writeFileSync(join(dir, "HARL", "my file.txt"), "tracked\n");
    git(join(dir, "HARL"), ["add", "my file.txt"]);
    git(join(dir, "HARL"), ["commit", "-m", "track spaced file"]);
    git(dir, ["add", "HARL"]);
    git(dir, ["commit", "-m", "record new pointer"]); // HARL clean at the new recorded commit
    writeFileSync(join(dir, "HARL", "my file.txt"), "tracked\nchanged\n");
    writeFileSync(join(dir, "HARL", "untracked file.txt"), "new\n");

    const status = await gitStatus(dir);
    expect(status.files.find((file) => file.path === "HARL/my file.txt")?.workingTree).toBe("modified");
    expect(status.files.some((file) => file.path === "HARL/untracked file.txt")).toBe(true);
    expect(status.files.find((file) => file.path === "HARL")).toBeUndefined(); // pointer unchanged
  });

  it("skips inner recursion without throwing when the submodule repo is unreadable", async () => {
    const { dir } = createFixture();
    writeFileSync(join(dir, "HARL", "new.txt"), "brand-new\n"); // untracked → would trigger recursion
    renameSync(join(dir, "HARL", ".git"), join(dir, "HARL", ".git.bak")); // break the inner repo

    const status = await gitStatus(dir);
    expect(status.isGitRepo).toBe(true);
    expect(status.files.some((file) => file.path.startsWith("HARL/"))).toBe(false);
  });
});

describe("Runtime-owned Git mutations", () => {
	it("stages, unstages, and commits only through the Git service projection", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-web-git-mutation-"));
		created.push(dir);
		git(dir, ["init", "-b", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "before\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		writeFileSync(join(dir, "tracked.txt"), "after\n");

		const staged = await gitStage(dir, ["tracked.txt"]);
		expect(staged.files).toEqual(expect.arrayContaining([
			expect.objectContaining({ path: "tracked.txt", index: "modified", workingTree: "unmodified" }),
		]));
		const unstaged = await gitUnstage(dir, ["tracked.txt"]);
		expect(unstaged.files).toEqual(expect.arrayContaining([
			expect.objectContaining({ path: "tracked.txt", index: "unmodified", workingTree: "modified" }),
		]));
		await gitStage(dir, ["tracked.txt"]);
		const committed = await gitCommit(dir, "native Runtime commit\n\nwith detail");
		expect(committed.hash).toMatch(/^[0-9a-f]{40}$/);
		expect(committed.subject).toBe("native Runtime commit");
		expect(committed.status.files).toEqual([]);
	});

	it("discards only an unstaged tracked root-worktree change", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-web-git-discard-"));
		created.push(dir);
		git(dir, ["init", "-b", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "before\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		writeFileSync(join(dir, "tracked.txt"), "after\n");

		const status = await gitDiscard(dir, ["tracked.txt"]);
		expect(status.files).toEqual([]);
		expect(readFileSync(join(dir, "tracked.txt"), "utf8")).toBe("before\n");
	});

	it("refuses unsafe discard shapes", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-web-git-discard-policy-"));
		created.push(dir);
		git(dir, ["init", "-b", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "before\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		writeFileSync(join(dir, "untracked.txt"), "new\n");
		await expect(gitDiscard(dir, ["untracked.txt"])).rejects.toThrow("Only a tracked, unstaged");
		writeFileSync(join(dir, "tracked.txt"), "staged\n");
		await gitStage(dir, ["tracked.txt"]);
		await expect(gitDiscard(dir, ["tracked.txt"])).rejects.toThrow("Only a tracked, unstaged");
	});

	it("stages, unstages, and discards tracked direct-submodule files in their owning worktree", async () => {
		const { dir } = createFixture();
		const submodule = join(dir, "HARL");
		writeFileSync(join(submodule, "a.txt"), "changed in submodule\n");

		const staged = await gitStage(dir, ["HARL/a.txt"]);
		expect(staged.files).toEqual(expect.arrayContaining([
			expect.objectContaining({ path: "HARL/a.txt", index: "modified", workingTree: "unmodified" }),
		]));
		const unstaged = await gitUnstage(dir, ["HARL/a.txt"]);
		expect(unstaged.files).toEqual(expect.arrayContaining([
			expect.objectContaining({ path: "HARL/a.txt", index: "unmodified", workingTree: "modified" }),
		]));

		const discarded = await gitDiscard(dir, ["HARL/a.txt"]);
		expect(discarded.files).toEqual([]);
		expect(readFileSync(join(submodule, "a.txt"), "utf8")).toBe("v2\n");
	});

	it("keeps submodule pointers outside the destructive discard operation", async () => {
		const { dir, c1 } = createFixture();
		git(join(dir, "HARL"), ["checkout", c1]);

		await expect(gitDiscard(dir, ["HARL"])).rejects.toThrow("Only a tracked, unstaged");
	});
});

describe("Runtime-owned latest-commit undo", () => {
	it("previews and reverts a clean, non-merge HEAD into a new inverse commit", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-web-git-revert-"));
		created.push(dir);
		git(dir, ["init", "-b", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "before\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		writeFileSync(join(dir, "tracked.txt"), "after\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "change file"]);
		const previousHead = git(dir, ["rev-parse", "HEAD"]).trim();

		const preview = await gitRevertPreview(dir);
		expect(preview).toMatchObject({ canRevert: true, commit: { hash: previousHead, subject: "change file" } });
		const reverted = await gitRevertHead(dir);
		expect(reverted.hash).not.toBe(previousHead);
		expect(reverted.subject).toBe('Revert "change file"');
		expect(reverted.status.files).toEqual([]);
		expect(readFileSync(join(dir, "tracked.txt"), "utf8")).toBe("before\n");
	});

	it("refuses a dirty worktree and a merge HEAD", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-web-git-revert-policy-"));
		created.push(dir);
		git(dir, ["init", "-b", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "initial\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		writeFileSync(join(dir, "tracked.txt"), "dirty\n");
		await expect(gitRevertHead(dir)).rejects.toThrow("Commit or clear all working-tree");
		git(dir, ["restore", "tracked.txt"]);
		git(dir, ["checkout", "-b", "topic"]);
		writeFileSync(join(dir, "topic.txt"), "topic\n");
		git(dir, ["add", "topic.txt"]);
		git(dir, ["commit", "-m", "topic"]);
		git(dir, ["checkout", "main"]);
		writeFileSync(join(dir, "main.txt"), "main\n");
		git(dir, ["add", "main.txt"]);
		git(dir, ["commit", "-m", "main"]);
		git(dir, ["merge", "--no-ff", "topic", "-m", "merge topic"]);
		const preview = await gitRevertPreview(dir);
		expect(preview).toMatchObject({ canRevert: false, reason: "Merge commits cannot be undone from the native inspector." });
	});
});

describe("Runtime-owned Git push", () => {
	it("previews and pushes only the configured tracking branch", async () => {
		const base = mkdtempSync(join(tmpdir(), "pi-web-git-push-"));
		created.push(base);
		const remote = join(base, "remote.git");
		const dir = join(base, "worktree");
		git(base, ["init", "--bare", remote]);
		git(base, ["init", "-b", "main", dir]);
		writeFileSync(join(dir, "tracked.txt"), "first\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		git(dir, ["remote", "add", "origin", remote]);
		git(dir, ["push", "-u", "origin", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "second\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "local commit"]);

		const preview = await gitPushPreview(dir);
		expect(preview).toMatchObject({ canPush: true, status: { branch: "main", upstream: "origin/main", ahead: 1, behind: 0 } });
		const status = await gitPush(dir);
		expect(status.ahead).toBe(0);
		expect(status.behind).toBe(0);
		expect(git(remote, ["rev-parse", "refs/heads/main"]).trim()).toBe(git(dir, ["rev-parse", "HEAD"]).trim());
	});

	it("refuses to push without a tracking upstream", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-web-git-push-policy-"));
		created.push(dir);
		git(dir, ["init", "-b", "main"]);
		writeFileSync(join(dir, "tracked.txt"), "initial\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);

		const noUpstream = await gitPushPreview(dir);
		expect(noUpstream).toMatchObject({ canPush: false, reason: "The current branch has no configured tracking upstream." });
		await expect(gitPush(dir)).rejects.toThrow("The current branch has no configured tracking upstream.");
	});

	it("refuses to push when the tracking upstream is ahead", async () => {
		const base = mkdtempSync(join(tmpdir(), "pi-web-git-push-behind-"));
		created.push(base);
		const remote = join(base, "remote.git");
		const dir = join(base, "worktree");
		const peer = join(base, "peer");
		git(base, ["init", "--bare", remote]);
		git(base, ["init", "-b", "main", dir]);
		writeFileSync(join(dir, "tracked.txt"), "initial\n");
		git(dir, ["add", "tracked.txt"]);
		git(dir, ["commit", "-m", "initial"]);
		git(dir, ["remote", "add", "origin", remote]);
		git(dir, ["push", "-u", "origin", "main"]);
		git(base, ["clone", "--branch", "main", remote, peer]);
		writeFileSync(join(peer, "peer.txt"), "from peer\n");
		git(peer, ["add", "peer.txt"]);
		git(peer, ["commit", "-m", "peer commit"]);
		git(peer, ["push", "origin", "main"]);
		git(dir, ["fetch", "origin"]);

		const preview = await gitPushPreview(dir);
		expect(preview).toMatchObject({
			canPush: false,
			reason: "The upstream has commits that are not present locally. Pull or rebase before pushing.",
			status: { ahead: 0, behind: 1 },
		});
		await expect(gitPush(dir)).rejects.toThrow("The upstream has commits that are not present locally. Pull or rebase before pushing.");
	});
});

describe("submodule paths containing spaces", () => {
  it("expands status and routes diffs into the space-named submodule", async () => {
    const { dir } = createSpacedPathFixture();
    writeFileSync(join(dir, "my sub", "a.txt"), "v1\nchanged\n");

    const status = await gitStatus(dir);
    expect(status.submodules).toContain("my sub");
    expect(status.files.some((file) => file.path === "my sub/a.txt")).toBe(true);

    const diff = await gitDiff(dir, { path: "my sub/a.txt" });
    expect(diff.path).toBe("my sub/a.txt");
    expect(diff.diff).toContain("@@");
    expect(diff.diff).toContain("changed");
  });
});

describe("gitDiff routing into submodules", () => {
  it("returns real content for a tracked file inside the submodule", async () => {
    const { dir } = createFixture();
    writeFileSync(join(dir, "HARL", "a.txt"), "v2\nchanged\n");

    const diff = await gitDiff(dir, { path: "HARL/a.txt" });
    expect(diff.path).toBe("HARL/a.txt");
    expect(diff.diff).toContain("@@");
    expect(diff.diff).toContain("changed");
  });

  it("produces an untracked-file diff inside the submodule via --no-index", async () => {
    const { dir } = createFixture();
    writeFileSync(join(dir, "HARL", "new.txt"), "brand-new\n");

    const diff = await gitDiff(dir, { path: "HARL/new.txt" });
    expect(diff.path).toBe("HARL/new.txt");
    expect(diff.diff).toContain("brand-new");
  });

  it("diffs the submodule path itself against the superproject pointer", async () => {
    const { dir, c1 } = createFixture();
    git(join(dir, "HARL"), ["checkout", c1]);

    const diff = await gitDiff(dir, { path: "HARL" });
    expect(diff.path).toBe("HARL");
    expect(diff.diff).toContain("Subproject commit");
  });
});
