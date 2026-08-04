import { mkdtemp, mkdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { NativeProjectCapabilityService } from "./nativeProjectCapability.js";

const roots: string[] = [];

afterEach(async () => {
	await Promise.all(roots.splice(0).map((root) => {
		return rm(root, { recursive: true, force: true });
	}));
});

describe("NativeProjectCapabilityService", () => {
	it("requires its private token and admits only the authorized root and descendants", async () => {
		const root = await mkdtemp(join(tmpdir(), "pi-agent-capability-"));
		roots.push(root);
		const project = join(root, "project");
		const nested = join(project, "nested");
		const sibling = join(root, "project-other");
		await Promise.all([mkdir(nested, { recursive: true }), mkdir(sibling)]);
		const service = new NativeProjectCapabilityService("token-1");

		expect(() => {
			service.assertToken("wrong");
		}).toThrow("capability");
		service.assertToken("token-1");
		await expect(service.assertAuthorizedCwd(nested)).rejects.toThrow("outside");
		expect(await service.authorize(project)).toBe(await realpath(project));
		await expect(service.assertAuthorizedCwd(project)).resolves.toBeUndefined();
		await expect(service.assertAuthorizedCwd(nested)).resolves.toBeUndefined();
		await expect(service.assertAuthorizedCwd(sibling)).rejects.toThrow("outside");
	});

	it("rejects malformed, unavailable, and non-directory project paths", async () => {
		const root = await mkdtemp(join(tmpdir(), "pi-agent-capability-"));
		roots.push(root);
		const file = join(root, "not-a-project");
		await writeFile(file, "not a directory", "utf8");
		const service = new NativeProjectCapabilityService("token-1");

		await expect(service.authorize("")).rejects.toThrow("required");
		await expect(service.authorize("relative/project")).rejects.toThrow("absolute");
		await expect(service.authorize(join(root, "missing"))).rejects.toThrow("unavailable");
		await expect(service.authorize(file)).rejects.toThrow("not a directory");
		await expect(service.assertAuthorizedCwd("relative/project")).rejects.toThrow("absolute");
		await expect(service.assertAuthorizedCwd(join(root, "missing"))).rejects.toThrow("unavailable");
	});

	it("does not let a symlink below an authorized project escape its canonical root", async () => {
		const root = await mkdtemp(join(tmpdir(), "pi-agent-capability-"));
		roots.push(root);
		const project = join(root, "project");
		const outside = join(root, "outside");
		const escape = join(project, "escape");
		await Promise.all([mkdir(project), mkdir(outside)]);
		await symlink(outside, escape);
		const service = new NativeProjectCapabilityService("token-1");

		await service.authorize(project);
		await expect(service.assertAuthorizedCwd(escape)).rejects.toThrow("outside");
	});
});
