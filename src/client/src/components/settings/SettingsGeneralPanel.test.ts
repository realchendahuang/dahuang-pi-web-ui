import { afterEach, describe, expect, it, vi } from "vitest";
import type { TemplateResult } from "lit";
import type {
	AgentRuntimesResponse,
	PiWebConfigEnvOverrides,
	PiWebConfigResponse,
	PiWebConfigValues,
} from "../../api";
import { DEFAULT_LOCALE, resetLocaleForTests, setLocale, t } from "../../i18n";
import { SettingsGeneralPanel } from "./SettingsGeneralPanel";
import type {
	GatewayServerConfigDraft,
	MachineAccessConfigDraft,
	OmpRuntimeConfigDraft,
} from "./settingsConfigDraft";

afterEach(() => {
	resetLocaleForTests(DEFAULT_LOCALE);
});

describe("settings-general-panel copy", () => {
	it("renders the compact settings frame without explanatory copy", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsGeneralPanel();
		panel.targetLabel = "Lab Mac (remote machine)";
		panel.configResponse = configResponse({ host: "127.0.0.1" });
		panel.machineConfigResponse = configResponse({
			pathAccess: { allowedPaths: ["/mnt/share"] },
			uploads: { defaultFolder: "manual/uploads" },
		});

		const template = panel.render();
		const strings = collectTemplateStrings(template).join("");
		const values = collectTemplateValues(template);

		expect(strings).toContain("<settings-panel-frame");
		expect(values).toContain(t("settings.general.gatewayHeading"));
		expect(values).toContain(t("settings.general.machineHeading"));
		expect(
			values.filter((value) => value === "Lab Mac (remote machine)"),
		).toHaveLength(0);
	});

	it("shows reload copy when selected-machine access config is unavailable", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsGeneralPanel();
		panel.targetLabel = "Lab Mac (remote machine)";
		panel.configResponse = configResponse({ host: "127.0.0.1" });
		panel.machineError =
			"Failed to load file access/upload config from Lab Mac (remote machine): unsupported";

		const template = panel.render();
		const values = collectTemplateValues(template);

		expect(values).toContain(t("settings.general.saveGateway"));
		expect(values).not.toContain(t("settings.general.saveMachine"));
		expect(values).toContain(t("settings.general.machineUnavailable"));
		expect(values).toContain(
			"Failed to load file access/upload config from Lab Mac (remote machine): unsupported",
		);
	});

	it("uses frame notices for saved and gateway messages while keeping selected-machine errors scoped", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsGeneralPanel();
		panel.error = "Gateway failed";
		panel.machineError = "Selected-machine failed";
		panel.savedMessage = "Config saved.";

		const values = collectTemplateValues(panel.render());
		const notices = values.find(isSettingsNoticeArray);

		expect(notices).toEqual([
			{
				type: "error",
				title: t("settings.general.noticeGateway"),
				content: "Gateway failed",
			},
			{ type: "success", content: "Config saved." },
		]);
		expect(values).toContain("Selected-machine failed");
	});

	it("defaults UI copy to Chinese", () => {
		resetLocaleForTests("zh");
		const panel = new SettingsGeneralPanel();
		const values = collectTemplateValues(panel.render());
		expect(values).toContain("通用配置");
		expect(values).toContain("界面语言");
	});
});

describe("settings-general-panel save payloads", () => {
	it("saves gateway server fields through the gateway save callback only", async () => {
		const panel = new SettingsGeneralPanel();
		const onSave = vi.fn();
		const onSaveMachineConfig = vi.fn();
		const event = new Event("submit", { cancelable: true });
		panel.configResponse = configResponse({
			host: "127.0.0.1",
			port: 31415,
			allowedHosts: ["old.local"],
			shortcuts: { "core:view.chat": "mod+1" },
			plugins: { info: { enabled: false } },
			pathAccess: { allowedPaths: ["/gateway"] },
			uploads: { defaultFolder: "gateway/uploads" },
			spawnSessions: true,
		});
		panel.onSave = onSave;
		panel.onSaveMachineConfig = onSaveMachineConfig;
		setPanelProperty(panel, "gatewayDraft", {
			host: " 0.0.0.0 ",
			port: "9000",
			allowedHostsMode: "all",
			allowedHostsText: "ignored.local",
		} satisfies GatewayServerConfigDraft);

		await callPanelPromise(panel, "saveGatewayConfig", event);

		expect(event.defaultPrevented).toBe(true);
		expect(onSave.mock.calls).toEqual([
			[
				{
					host: "0.0.0.0",
					port: 9000,
					allowedHosts: true,
					shortcuts: { "core:view.chat": "mod+1" },
					plugins: { info: { enabled: false } },
					pathAccess: { allowedPaths: ["/gateway"] },
					uploads: { defaultFolder: "gateway/uploads" },
					spawnSessions: true,
				},
			],
		]);
		expect(onSaveMachineConfig).not.toHaveBeenCalled();
		expect(getPanelProperty(panel, "gatewayLocalError")).toBe("");
	});

	it("saves external roots and upload defaults through the selected-machine save callback only", async () => {
		const panel = new SettingsGeneralPanel();
		const onSave = vi.fn();
		const onSaveMachineConfig = vi.fn();
		const event = new Event("submit", { cancelable: true });
		panel.onSave = onSave;
		panel.onSaveMachineConfig = onSaveMachineConfig;
		setPanelProperty(panel, "machineDraft", {
			allowedPathsText: "/tmp\n~/SDKs\n",
			uploadDefaultFolder: " manual\\uploads/. ",
		} satisfies MachineAccessConfigDraft);

		await callPanelPromise(panel, "saveMachineAccessConfig", event);

		expect(event.defaultPrevented).toBe(true);
		expect(onSaveMachineConfig.mock.calls).toEqual([
			[
				{
					pathAccess: { allowedPaths: ["/tmp", "~/SDKs"] },
					uploads: { defaultFolder: "manual/uploads" },
				},
			],
		]);
		expect(onSave).not.toHaveBeenCalled();
		expect(getPanelProperty(panel, "machineLocalError")).toBe("");
	});

	it("keeps invalid upload folders local and does not save selected-machine config", async () => {
		const panel = new SettingsGeneralPanel();
		const onSaveMachineConfig = vi.fn();
		panel.onSaveMachineConfig = onSaveMachineConfig;
		setPanelProperty(panel, "machineDraft", {
			allowedPathsText: "",
			uploadDefaultFolder: "/tmp/uploads",
		} satisfies MachineAccessConfigDraft);

		await callPanelPromise(
			panel,
			"saveMachineAccessConfig",
			new Event("submit", { cancelable: true }),
		);

		expect(onSaveMachineConfig).not.toHaveBeenCalled();
		expect(getPanelProperty(panel, "machineLocalError")).toBe(
			"Upload default folder must be workspace-relative.",
		);
	});
});

function collectTemplateStrings(template: TemplateResult): string[] {
	const strings: string[] = [];
	visitTemplate(template);
	return strings;

	function visitTemplate(current: TemplateResult): void {
		strings.push(...templateStrings(current));
		for (const value of templateValues(current)) {
			if (Array.isArray(value)) {
				for (const item of value)
					if (isTemplateResult(item)) visitTemplate(item);
			} else if (isTemplateResult(value)) {
				visitTemplate(value);
			}
		}
	}
}

function collectTemplateValues(template: TemplateResult): unknown[] {
	const values: unknown[] = [];
	visit(template);
	return values;

	function visit(current: unknown): void {
		if (Array.isArray(current)) {
			for (const item of current) visit(item);
			return;
		}
		if (!isTemplateResult(current)) return;
		for (const value of templateValues(current)) {
			values.push(value);
			visit(value);
		}
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

function isSettingsNoticeArray(
	value: unknown,
): value is readonly { type: string; content: unknown; title?: string }[] {
	return (
		Array.isArray(value) &&
		value.length > 0 &&
		value.every(
			(item: unknown) =>
				typeof item === "object" &&
				item !== null &&
				typeof Reflect.get(item, "type") === "string" &&
				Reflect.has(item, "content"),
		)
	);
}

// TemplateResult binding extraction (testing-guide escape hatch): these tests
// run in Node without a DOM, so checking that env overrides disable the
// runtime controls means inspecting the rendered template. The lookup anchors
// on stable user-facing markup (the radio group name / input placeholder) and
// reads only the boolean `?disabled=` bindings that follow, in template order.
function disabledBindingsAnchoredAt(
	template: TemplateResult,
	anchor: string,
): boolean[] {
	const bindings: boolean[] = [];
	visit(template);
	if (bindings.length === 0)
		throw new Error(`No ?disabled= bindings found near ${anchor}`);
	return bindings;

	function visit(current: TemplateResult): void {
		const strings = templateStrings(current);
		const values = templateValues(current);
		if (strings.some((chunk) => chunk.includes(anchor))) {
			strings.forEach((chunk, index) => {
				if (!chunk.endsWith("?disabled=")) return;
				const value = values[index];
				if (typeof value !== "boolean")
					throw new Error(`Expected a boolean ?disabled= binding near ${anchor}`);
				bindings.push(value);
			});
		}
		for (const value of values) {
			if (Array.isArray(value)) {
				for (const item of value)
					if (isTemplateResult(item)) visit(item);
			} else if (isTemplateResult(value)) {
				visit(value);
			}
		}
	}
}

function isStringArray(value: unknown): value is string[] {
	return (
		Array.isArray(value) &&
		value.every((item: unknown) => typeof item === "string")
	);
}

function setPanelProperty(
	panel: SettingsGeneralPanel,
	property: string,
	value: unknown,
): void {
	if (!Reflect.set(panel, property, value))
		throw new Error(`Failed to set SettingsGeneralPanel property ${property}`);
}

function getPanelProperty(
	panel: SettingsGeneralPanel,
	property: string,
): unknown {
	return Reflect.get(panel, property);
}

async function callPanelPromise(
	panel: SettingsGeneralPanel,
	methodName: string,
	...args: readonly unknown[]
): Promise<void> {
	const result = callPanelMethod(panel, methodName, ...args);
	if (!(result instanceof Promise))
		throw new Error(
			`SettingsGeneralPanel.${methodName} did not return a promise`,
		);
	await result;
}

function callPanelMethod(
	panel: SettingsGeneralPanel,
	methodName: string,
	...args: readonly unknown[]
): unknown {
	const method: unknown = Reflect.get(panel, methodName);
	if (!isPanelMethod(method))
		throw new Error(`SettingsGeneralPanel.${methodName} is not callable`);
	return method.call(panel, ...args);
}

function isPanelMethod(
	value: unknown,
): value is (
	this: SettingsGeneralPanel,
	...args: readonly unknown[]
) => unknown {
	return typeof value === "function";
}

describe("settings-general-panel agent runtimes", () => {
	it("renders localized runtime status badges and availability details", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsGeneralPanel();
		panel.agentRuntimeCatalog = runtimeCatalog();

		const values = collectTemplateValues(panel.render());

		expect(values).toContain(t("settings.general.runtimesHeading"));
		expect(values).toContain(t("settings.general.runtimeAvailable"));
		expect(values).toContain(t("settings.general.runtimeUnavailable"));
		expect(values).toContain("/usr/local/bin/omp");
		expect(values).toContain("~/.omp/agent");
		expect(values).toContain("omp executable not found on PATH");
	});

	it("switches the default runtime through the selected-machine save callback, preserving the OMP profile", async () => {
		const panel = new SettingsGeneralPanel();
		const onSaveMachineConfig = vi.fn();
		panel.agentRuntimeCatalog = runtimeCatalog();
		panel.machineConfigResponse = configResponse({
			agentRuntimes: { default: "pi", omp: { command: "omp-dev" } },
		});
		panel.onSaveMachineConfig = onSaveMachineConfig;

		await callPanelPromise(panel, "changeDefaultRuntime", "omp");

		expect(onSaveMachineConfig.mock.calls).toEqual([
			[{ agentRuntimes: { default: "omp", omp: { command: "omp-dev" } } }],
		]);
		expect(getPanelProperty(panel, "runtimesLocalError")).toBe("");
	});

	it("saves OMP command/dir drafts through the selected-machine save callback, preserving the default runtime", async () => {
		const panel = new SettingsGeneralPanel();
		const onSaveMachineConfig = vi.fn();
		const event = new Event("submit", { cancelable: true });
		panel.agentRuntimeCatalog = runtimeCatalog();
		panel.machineConfigResponse = configResponse({
			agentRuntimes: { default: "pi" },
		});
		panel.onSaveMachineConfig = onSaveMachineConfig;
		setPanelProperty(panel, "ompDraft", {
			command: " omp-dev ",
			dir: " ~/omp-profiles/dev ",
		} satisfies OmpRuntimeConfigDraft);

		await callPanelPromise(panel, "saveAgentRuntimesConfig", event);

		expect(event.defaultPrevented).toBe(true);
		expect(onSaveMachineConfig.mock.calls).toEqual([
			[
				{
					agentRuntimes: {
						default: "pi",
						omp: { command: "omp-dev", dir: "~/omp-profiles/dev" },
					},
				},
			],
		]);
		expect(getPanelProperty(panel, "runtimesLocalError")).toBe("");
	});

	it("keeps runtime save errors local and does not report them as machine access errors", async () => {
		const panel = new SettingsGeneralPanel();
		panel.agentRuntimeCatalog = runtimeCatalog();
		panel.machineConfigResponse = configResponse({});
		panel.onSaveMachineConfig = () => Promise.reject(new Error("save failed"));

		await callPanelPromise(
			panel,
			"saveAgentRuntimesConfig",
			new Event("submit", { cancelable: true }),
		);

		expect(getPanelProperty(panel, "runtimesLocalError")).toBe("save failed");
		expect(getPanelProperty(panel, "machineLocalError")).toBe("");
		expect(collectTemplateValues(panel.render())).toContain("save failed");
	});

	it("locks the default runtime radios and OMP inputs when environment overrides pin them", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsGeneralPanel();
		panel.agentRuntimeCatalog = runtimeCatalog();
		panel.machineConfigResponse = configResponse(
			{},
			{ ompCommand: true, ompAgentDir: true, defaultRuntime: true },
		);

		const template = panel.render();

		expect(
			disabledBindingsAnchoredAt(template, 'name="default-agent-runtime"'),
		).toEqual([true, true]);
		expect(disabledBindingsAnchoredAt(template, 'placeholder="omp"')).toEqual([
			true,
			true,
			true,
		]);
		const values = collectTemplateValues(template);
		expect(values.filter((value) => value === t("common.envOverride"))).toHaveLength(3);
	});

	it("leaves runtime editing enabled when no environment overrides apply", () => {
		setLocale("en", { persist: false });
		const panel = new SettingsGeneralPanel();
		panel.agentRuntimeCatalog = runtimeCatalog();
		panel.machineConfigResponse = configResponse({});

		const template = panel.render();

		// The unavailable OMP runtime cannot be selected as the default.
		expect(
			disabledBindingsAnchoredAt(template, 'name="default-agent-runtime"'),
		).toEqual([false, true]);
		expect(disabledBindingsAnchoredAt(template, 'placeholder="omp"')).toEqual([
			false,
			false,
			false,
		]);
	});

	it("hides runtime editing when the selected-machine config is unavailable", () => {
		const panel = new SettingsGeneralPanel();
		panel.agentRuntimeCatalog = runtimeCatalog();

		const template = panel.render();
		const strings = collectTemplateStrings(template).join("");
		const values = collectTemplateValues(template);

		expect(values).toContain(t("settings.general.runtimesHeading"));
		expect(strings).not.toContain('name="default-agent-runtime"');
		expect(strings).not.toContain('placeholder="omp"');
	});
});

function runtimeCatalog(): AgentRuntimesResponse {
	return {
		defaultRuntimeId: "pi",
		runtimes: [
			{
				id: "pi",
				kind: "pi-embedded",
				label: "Pi",
				available: true,
				command: "pi",
				profileDir: "~/.pi/agent",
				capabilities: [],
				version: "1.2.3",
			},
			{
				id: "omp",
				kind: "omp-rpc",
				label: "OMP",
				available: false,
				command: "/usr/local/bin/omp",
				profileDir: "~/.omp/agent",
				capabilities: [],
				unavailableReason: "omp executable not found on PATH",
			},
		],
	};
}

function configResponse(
	config: PiWebConfigValues,
	envOverrides: Partial<PiWebConfigEnvOverrides> = {},
): PiWebConfigResponse {
	return {
		path: "/tmp/pi-web/config.json",
		exists: true,
		config,
		effectiveConfig: config,
		envOverrides: {
			host: false,
			port: false,
			allowedHosts: false,
			spawnSessions: false,
			subsessions: false,
			agentCommand: false,
			agentDir: false,
			agentSessionDir: false,
			...envOverrides,
		},
	};
}
