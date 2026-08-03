import { afterEach, describe, expect, it } from "vitest";
import type { TemplateResult } from "lit";
import type { OmpConfigResponse, OmpSettingDescriptor } from "../../api";
import { DEFAULT_LOCALE, resetLocaleForTests, setLocale, t } from "../../i18n";
import {
	filterOmpSettings,
	groupOmpSettings,
	ompSettingChanges,
	SettingsOmpPanel,
} from "./SettingsOmpPanel";
import type { SettingsNotice } from "./SettingsPanelFrame";

afterEach(() => {
	resetLocaleForTests(DEFAULT_LOCALE);
});

function setting(
	key: string,
	overrides: Partial<OmpSettingDescriptor> = {},
): OmpSettingDescriptor {
	return { key, type: "string", description: "", value: "", ...overrides };
}

function ompResponse(settings: OmpSettingDescriptor[]): OmpConfigResponse {
	return { available: true, command: "/usr/local/bin/omp", settings };
}

describe("groupOmpSettings", () => {
	it("groups settings by tab then group and pushes untabbed settings to other", () => {
		const groups = groupOmpSettings([
			setting("model.name", { tab: "model", group: "selection" }),
			setting("model.temperature", { tab: "model", group: "sampling" }),
			setting("model.thinking", { tab: "model", group: "selection" }),
			setting("bash.timeout", { tab: "tools" }),
			setting("extensions"),
		]);

		expect(groups.map((group) => group.tab)).toEqual(["model", "tools", "other"]);
		const model = groups[0];
		expect(model?.sections.map((section) => section.name)).toEqual([
			"selection",
			"sampling",
		]);
		expect(
			model?.sections[0]?.settings.map((entry) => entry.key),
		).toEqual(["model.name", "model.thinking"]);
		expect(groups[1]?.sections[0]?.name).toBe("");
		expect(groups[2]?.sections[0]?.settings[0]?.key).toBe("extensions");
	});
});

describe("filterOmpSettings", () => {
	it("matches keys and descriptions case-insensitively", () => {
		const settings = [
			setting("model.name", { description: "Active model" }),
			setting("bash.timeout", { description: "Shell command timeout" }),
		];

		expect(filterOmpSettings(settings, "MODEL").map((entry) => entry.key)).toEqual([
			"model.name",
		]);
		expect(filterOmpSettings(settings, "timeout").map((entry) => entry.key)).toEqual([
			"bash.timeout",
		]);
		expect(filterOmpSettings(settings, "  ")).toHaveLength(2);
		expect(filterOmpSettings(settings, "zzz")).toEqual([]);
	});
});

describe("ompSettingChanges", () => {
	it("submits only the edited subset that differs from loaded values", () => {
		const settings = [
			setting("tools.enabled", { type: "boolean", value: true }),
			setting("model.temperature", { type: "number", value: 0.7 }),
			setting("model.name", { type: "enum", value: "k3" }),
			setting("extensions", { type: "array", value: ["a.ts"] }),
		];

		const changes = ompSettingChanges(settings, {
			"tools.enabled": false,
			"model.temperature": 0.7,
			"model.name": null,
			extensions: ["a.ts"],
			"unknown.key": "ignored",
		});

		expect(changes).toEqual({ "tools.enabled": false, "model.name": null });
	});
});

describe("settings-omp-panel layout", () => {
	it("renders settings grouped under tab and group headings", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsOmpPanel();
		panel.targetLabel = "Lab Mac (remote machine)";
		panel.ompResponse = ompResponse([
			setting("model.name", {
				type: "enum",
				value: "k3",
				enumValues: ["k3", "k2"],
				description: "Active model",
				tab: "model",
				group: "selection",
			}),
			setting("tools.enabled", {
				type: "boolean",
				value: true,
				tab: "tools",
			}),
			setting("extensions", { type: "array", value: ["a.ts"] }),
		]);

		const rendered = flattenTemplateContent(panel.render());

		expectTextOrder(rendered, [
			t("settings.omp.heading"),
			"model",
			"selection",
			"model.name",
			"tools",
			"tools.enabled",
			t("settings.omp.otherTab"),
			"extensions",
		]);
	});

	it("filters the rendered settings with the search box query", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsOmpPanel();
		panel.ompResponse = ompResponse([
			setting("model.name", { description: "Active model" }),
			setting("bash.timeout", { description: "Shell command timeout" }),
		]);
		// Simulate the user typing into the search input.
		Reflect.set(panel, "searchQuery", "timeout");

		const rendered = flattenTemplateContent(panel.render());

		expect(rendered).toContain("bash.timeout");
		expect(rendered).not.toContain("model.name");
	});

	it("shows the omp error with a retry path when omp is unavailable", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsOmpPanel();
		panel.targetLabel = "Lab Mac (remote machine)";
		panel.ompResponse = {
			available: false,
			error: "OMP executable not found: omp",
			settings: [],
		};

		const rendered = flattenTemplateContent(panel.render());

		expect(rendered).toContain("OMP executable not found: omp");
		expect(rendered).toContain(t("common.reload"));
	});

	it("resets local edits when a fresh payload arrives", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsOmpPanel();
		panel.ompResponse = ompResponse([
			setting("tools.enabled", { type: "boolean", value: true }),
		]);
		Reflect.set(panel, "edits", { "tools.enabled": false });
		Reflect.set(panel, "jsonErrors", { extensions: "Invalid JSON" });

		// willUpdate is a protected Lit lifecycle hook; invoking it through Reflect
		// keeps this a property-reset test without a DOM/custom-element harness.
		const willUpdate: unknown = Reflect.get(panel, "willUpdate");
		if (typeof willUpdate !== "function")
			throw new Error("SettingsOmpPanel.willUpdate is not callable");
		willUpdate.call(panel, new Map([["ompResponse", panel.ompResponse]]));

		expect(Reflect.get(panel, "edits")).toEqual({});
		expect(Reflect.get(panel, "jsonErrors")).toEqual({});
	});
});

function flattenTemplateContent(template: TemplateResult): string {
	const chunks: string[] = [];
	visitTemplate(template);
	return chunks.join("");

	function visitTemplate(current: TemplateResult): void {
		const strings = templateStrings(current);
		const values = templateValues(current);
		for (let index = 0; index < values.length; index += 1) {
			const staticChunk = strings[index];
			if (staticChunk !== undefined) chunks.push(staticChunk);
			visitValue(values[index]);
		}
		const finalChunk = strings[values.length];
		if (finalChunk !== undefined) chunks.push(finalChunk);
	}

	function visitValue(value: unknown): void {
		if (Array.isArray(value)) {
			for (const item of value) visitValue(item);
			return;
		}
		if (isSettingsNotice(value)) {
			visitValue(value.title);
			visitValue(value.content);
			return;
		}
		if (isTemplateResult(value)) {
			visitTemplate(value);
			return;
		}
		if (
			typeof value === "string" ||
			typeof value === "number" ||
			typeof value === "boolean"
		) {
			chunks.push(String(value));
		}
	}
}

function expectTextOrder(content: string, labels: readonly string[]): void {
	let previousIndex = -1;
	for (const label of labels) {
		const currentIndex = content.indexOf(label, previousIndex + 1);
		if (currentIndex === -1)
			throw new Error(`Expected rendered content to include ${label}`);
		expect(currentIndex).toBeGreaterThan(previousIndex);
		previousIndex = currentIndex;
	}
}

function templateStrings(template: TemplateResult): readonly string[] {
	const strings = Reflect.get(template, "strings");
	if (!isStringArray(strings))
		throw new Error("TemplateResult strings were unavailable");
	return strings;
}

function templateValues(template: TemplateResult): readonly unknown[] {
	const values = Reflect.get(template, "values");
	if (!Array.isArray(values))
		throw new Error("TemplateResult values were unavailable");
	return values.map((value: unknown) => value);
}

function isTemplateResult(value: unknown): value is TemplateResult {
	return (
		typeof value === "object" &&
		value !== null &&
		isStringArray(Reflect.get(value, "strings")) &&
		Array.isArray(Reflect.get(value, "values"))
	);
}

function isSettingsNotice(value: unknown): value is SettingsNotice {
	return (
		!isTemplateResult(value) &&
		typeof value === "object" &&
		value !== null &&
		"type" in value &&
		"content" in value
	);
}

function isStringArray(value: unknown): value is string[] {
	return Array.isArray(value) && value.every((item) => typeof item === "string");
}
