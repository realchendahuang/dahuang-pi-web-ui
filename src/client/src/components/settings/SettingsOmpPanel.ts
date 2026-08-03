import {
	css,
	html,
	LitElement,
	nothing,
	type PropertyValues,
	type TemplateResult,
} from "lit";
import { customElement, property, state } from "lit/decorators.js";
import type { OmpConfigResponse, OmpSettingDescriptor } from "../../api";
import { LocaleController, t } from "../../i18n";
import "./SettingsPanelFrame";
import type { SettingsNotice } from "./SettingsPanelFrame";
import {
	isSelectedMachineSettingsUnsupported,
	type SelectedMachineSettingsSupport,
} from "./settingsMachineTarget";

export interface OmpSettingGroupSection {
	name: string;
	settings: OmpSettingDescriptor[];
}

export interface OmpSettingTabGroup {
	tab: string;
	sections: OmpSettingGroupSection[];
}

/** Tab used for settings whose schema entry declares no `ui.tab`. */
export const OMP_SETTINGS_OTHER_TAB = "other";

/** Case-insensitive key/description search over OMP setting descriptors. */
export function filterOmpSettings(
	settings: readonly OmpSettingDescriptor[],
	query: string,
): OmpSettingDescriptor[] {
	const normalized = query.trim().toLowerCase();
	if (normalized === "") return [...settings];
	return settings.filter(
		(setting) =>
			setting.key.toLowerCase().includes(normalized) ||
			setting.description.toLowerCase().includes(normalized),
	);
}

/**
 * Groups settings by schema `ui.tab` then `ui.group`, preserving first-seen
 * order; settings without a tab land in the trailing "other" tab.
 */
export function groupOmpSettings(
	settings: readonly OmpSettingDescriptor[],
): OmpSettingTabGroup[] {
	const tabs = new Map<string, Map<string, OmpSettingDescriptor[]>>();
	for (const setting of settings) {
		const tab = setting.tab ?? OMP_SETTINGS_OTHER_TAB;
		const group = setting.group ?? "";
		let sections = tabs.get(tab);
		if (sections === undefined) {
			sections = new Map();
			tabs.set(tab, sections);
		}
		const bucket = sections.get(group);
		if (bucket === undefined) sections.set(group, [setting]);
		else bucket.push(setting);
	}
	return [...tabs.entries()]
		.map(([tab, sections]) => ({
			tab,
			sections: [...sections.entries()].map(([name, bucket]) => ({
				name,
				settings: bucket,
			})),
		}))
		.sort((a, b) => {
			if (a.tab === OMP_SETTINGS_OTHER_TAB) return 1;
			if (b.tab === OMP_SETTINGS_OTHER_TAB) return -1;
			return 0;
		});
}

function ompSettingValueEquals(a: unknown, b: unknown): boolean {
	if (Object.is(a, b)) return true;
	if (typeof a !== "object" || typeof b !== "object" || a === null || b === null)
		return false;
	return JSON.stringify(a) === JSON.stringify(b);
}

/** The locally edited subset that actually differs from the loaded values. */
export function ompSettingChanges(
	settings: readonly OmpSettingDescriptor[],
	edits: Readonly<Record<string, unknown>>,
): Record<string, unknown> {
	const values: Record<string, unknown> = {};
	const byKey = new Map(settings.map((setting) => [setting.key, setting]));
	for (const [key, value] of Object.entries(edits)) {
		const descriptor = byKey.get(key);
		if (descriptor === undefined) continue;
		if (!ompSettingValueEquals(descriptor.value, value)) values[key] = value;
	}
	return values;
}

function inputValue(event: Event): string {
	return event.target instanceof HTMLInputElement ? event.target.value : "";
}

function inputChecked(event: Event): boolean | undefined {
	return event.target instanceof HTMLInputElement
		? event.target.checked
		: undefined;
}

function selectValue(event: Event): string {
	return event.target instanceof HTMLSelectElement ? event.target.value : "";
}

function textAreaValue(event: Event): string {
	return event.target instanceof HTMLTextAreaElement ? event.target.value : "";
}

@customElement("settings-omp-panel")
export class SettingsOmpPanel extends LitElement {
	@property({ attribute: false }) ompResponse: OmpConfigResponse | undefined;
	@property({ type: Boolean }) loading = false;
	@property({ type: Boolean }) saving = false;
	@property() error = "";
	@property() savedMessage = "";
	@property() targetLabel = "local (local gateway)";
	@property({ attribute: false }) support:
		| SelectedMachineSettingsSupport
		| undefined;
	@property({ attribute: false }) onReload?: () => void | Promise<void>;
	@property({ attribute: false }) onSave?: (
		values: Record<string, unknown>,
	) => void | Promise<void>;
	@state() private searchQuery = "";
	@state() private edits: Record<string, unknown> = {};
	@state() private jsonDrafts: Record<string, string> = {};
	@state() private jsonErrors: Record<string, string> = {};
	private readonly locale = new LocaleController(this);

	protected override willUpdate(changed: PropertyValues<this>): void {
		if (changed.has("ompResponse")) {
			// A fresh payload (load, save, or machine switch) owns the values again.
			this.edits = {};
			this.jsonDrafts = {};
			this.jsonErrors = {};
			this.searchQuery = "";
		}
	}

	override render(): TemplateResult {
		void this.locale.locale;
		return html`
      <settings-panel-frame
        heading=${t("settings.omp.heading")}
        actionLabel=${t("common.reload")}
        .actionDisabled=${this.loading || this.saving}
        .notices=${this.panelNotices()}
        .onAction=${this.onReload}
      >
        ${this.renderPanelContent()}
      </settings-panel-frame>
    `;
	}

	private panelNotices(): readonly SettingsNotice[] {
		const notices: SettingsNotice[] = [];
		if (this.error !== "") notices.push({ type: "error", content: this.error });
		if (this.savedMessage !== "")
			notices.push({ type: "success", content: this.savedMessage });
		return notices;
	}

	private renderPanelContent(): TemplateResult {
		if (isSelectedMachineSettingsUnsupported(this.support)) {
			return html`<div class="loading-card">${this.support.message ?? t("settings.omp.unavailable", { target: this.targetLabel })}</div>`;
		}
		const response = this.ompResponse;
		if (response === undefined) {
			return html`<div class="loading-card">${this.loading ? t("settings.omp.loading") : t("settings.omp.unavailable", { target: this.targetLabel })}</div>`;
		}
		if (!response.available) {
			return html`
        <div class="loading-card">
          <p>${response.error ?? t("settings.omp.unavailable", { target: this.targetLabel })}</p>
          <button class="secondary" @click=${() => void this.onReload?.()}>${t("common.reload")}</button>
        </div>
      `;
		}
		const filtered = filterOmpSettings(response.settings, this.searchQuery);
		return html`
      ${response.configPath === undefined
				? nothing
				: html`<div class="config-path">${t("settings.omp.configFile", { path: response.configPath })}</div>`}
      <input
        class="search"
        type="search"
        aria-label=${t("settings.omp.searchAria")}
        placeholder=${t("settings.omp.searchPlaceholder")}
        .value=${this.searchQuery}
        @input=${(event: Event) => {
					this.searchQuery = inputValue(event);
				}}
      >
      ${this.renderSettings(filtered)}
      <div class="save-bar">
        <button
          class="primary"
          ?disabled=${this.pendingChanges().length === 0 || this.saving}
          @click=${() => void this.save()}
        >${this.saving ? t("common.saving") : t("settings.omp.saveChanges")}</button>
      </div>
    `;
	}

	private renderSettings(
		filtered: readonly OmpSettingDescriptor[],
	): TemplateResult {
		if (this.ompResponse === undefined || this.ompResponse.settings.length === 0) {
			return html`<div class="loading-card">${t("settings.omp.empty", { target: this.targetLabel })}</div>`;
		}
		if (filtered.length === 0) {
			return html`<div class="loading-card">${t("settings.omp.noMatches", { query: this.searchQuery.trim() })}</div>`;
		}
		return html`
      <div class="settings-groups">
        ${groupOmpSettings(filtered).map((tab) => this.renderTab(tab))}
      </div>
    `;
	}

	private renderTab(tab: OmpSettingTabGroup): TemplateResult {
		const label =
			tab.tab === OMP_SETTINGS_OTHER_TAB ? t("settings.omp.otherTab") : tab.tab;
		return html`
      <section class="setting-tab">
        <h3>${label}</h3>
        ${tab.sections.map(
					(section) => html`
            ${section.name === ""
							? nothing
							: html`<h4>${section.name}</h4>`}
            ${section.settings.map((setting) => this.renderSetting(setting))}
          `,
				)}
      </section>
    `;
	}

	private renderSetting(setting: OmpSettingDescriptor): TemplateResult {
		return html`
      <article class="setting-row" data-key=${setting.key}>
        <div class="setting-copy">
          <strong>${setting.key}</strong>
          ${setting.description === ""
						? nothing
						: html`<p>${setting.description}</p>`}
          ${setting.default === undefined
						? nothing
						: html`<small>${t("settings.omp.defaultLabel", { value: JSON.stringify(setting.default) })}</small>`}
        </div>
        <div class="setting-control">${this.renderControl(setting)}</div>
      </article>
    `;
	}

	private renderControl(setting: OmpSettingDescriptor): TemplateResult {
		const disabled = this.saving;
		switch (setting.type) {
			case "boolean": {
				const checked = this.editedValue(setting) === true;
				return html`
          <label class="toggle">
            <input
              type="checkbox"
              .checked=${checked}
              ?disabled=${disabled}
              @change=${(event: Event) => {
								this.handleBooleanChange(setting, event);
							}}
            >
            <span>${checked ? t("common.enabled") : t("common.disabled")}</span>
          </label>
        `;
			}
			case "number": {
				return html`
          <input
            type="number"
            step="any"
            .value=${this.editedText(setting)}
            ?disabled=${disabled}
            @change=${(event: Event) => {
							this.handleNumberChange(setting, event);
						}}
          >
        `;
			}
			case "enum": {
				if (setting.enumValues === undefined || setting.enumValues.length === 0)
					return this.renderTextControl(setting, disabled);
				return html`
          <select
            .value=${this.editedText(setting)}
            ?disabled=${disabled}
            @change=${(event: Event) => {
							this.setEdit(setting.key, selectValue(event));
						}}
          >
            ${setting.enumValues.map(
							(option) => html`<option value=${option} ?selected=${option === this.editedText(setting)}>${option}</option>`,
						)}
          </select>
        `;
			}
			case "string":
				return this.renderTextControl(setting, disabled);
			case "array":
			case "record": {
				const draft =
					this.jsonDrafts[setting.key] ??
					JSON.stringify(this.editedValue(setting) ?? null, null, 2);
				const error = this.jsonErrors[setting.key];
				return html`
          <textarea
            rows="3"
            spellcheck="false"
            .value=${draft}
            ?disabled=${disabled}
            @input=${(event: Event) => {
							this.jsonDrafts = {
								...this.jsonDrafts,
								[setting.key]: textAreaValue(event),
							};
						}}
            @blur=${(event: Event) => {
							this.commitJsonDraft(setting, textAreaValue(event));
						}}
          ></textarea>
          ${error === undefined
						? nothing
						: html`<small class="json-error">${error}</small>`}
        `;
			}
		}
	}

	private renderTextControl(
		setting: OmpSettingDescriptor,
		disabled: boolean,
	): TemplateResult {
		return html`
      <input
        type="text"
        .value=${this.editedText(setting)}
        ?disabled=${disabled}
        @change=${(event: Event) => {
					this.setEdit(setting.key, inputValue(event));
				}}
      >
    `;
	}

	private handleBooleanChange(
		setting: OmpSettingDescriptor,
		event: Event,
	): void {
		const checked = inputChecked(event);
		if (checked !== undefined) this.setEdit(setting.key, checked);
	}

	private handleNumberChange(setting: OmpSettingDescriptor, event: Event): void {
		const raw = inputValue(event);
		const parsed = Number(raw);
		if (raw.trim() !== "" && Number.isFinite(parsed))
			this.setEdit(setting.key, parsed);
	}

	private editedValue(setting: OmpSettingDescriptor): unknown {
		return setting.key in this.edits ? this.edits[setting.key] : setting.value;
	}

	private editedText(setting: OmpSettingDescriptor): string {
		const value = this.editedValue(setting);
		if (typeof value === "string") return value;
		if (typeof value === "number" && Number.isFinite(value)) return String(value);
		if (typeof value === "boolean") return value ? "true" : "false";
		return "";
	}

	private setEdit(key: string, value: unknown): void {
		this.edits = { ...this.edits, [key]: value };
	}

	private commitJsonDraft(setting: OmpSettingDescriptor, draft: string): void {
		try {
			const parsed: unknown = JSON.parse(draft);
			this.setEdit(setting.key, parsed);
			this.jsonErrors = Object.fromEntries(
				Object.entries(this.jsonErrors).filter(([key]) => key !== setting.key),
			);
		} catch (error) {
			this.jsonErrors = {
				...this.jsonErrors,
				[setting.key]: t("settings.omp.invalidJson", {
					message: error instanceof Error ? error.message : String(error),
				}),
			};
		}
	}

	private pendingChanges(): string[] {
		if (this.ompResponse === undefined) return [];
		return Object.keys(
			ompSettingChanges(this.ompResponse.settings, this.validEdits()),
		);
	}

	private validEdits(): Record<string, unknown> {
		const edits: Record<string, unknown> = {};
		for (const [key, value] of Object.entries(this.edits)) {
			if (key in this.jsonErrors) continue;
			edits[key] = value;
		}
		return edits;
	}

	private async save(): Promise<void> {
		if (this.ompResponse === undefined || this.saving) return;
		const values = ompSettingChanges(this.ompResponse.settings, this.validEdits());
		if (Object.keys(values).length === 0) return;
		await this.onSave?.(values);
	}

	static override styles = css`
    :host { display: block; }
    .loading-card { border: 1px solid var(--pi-border); border-radius: 10px; background: var(--pi-surface); padding: 16px; color: var(--pi-muted); }
    .loading-card p { margin: 0 0 10px; color: var(--pi-text); }
    .config-path { color: var(--pi-muted); font-size: 12px; overflow-wrap: anywhere; }
    .search { box-sizing: border-box; width: 100%; border: 1px solid var(--pi-border); border-radius: 8px; background: var(--pi-surface); color: var(--pi-text); padding: 8px 10px; font: inherit; }
    .settings-groups { display: grid; gap: 18px; }
    .setting-tab { display: grid; gap: 8px; }
    h3 { margin: 0; font-size: 14px; text-transform: capitalize; }
    h4 { margin: 4px 0 0; color: var(--pi-muted); font-size: 12px; font-weight: 600; text-transform: capitalize; }
    .setting-row { display: grid; grid-template-columns: minmax(0, 1fr) minmax(180px, 260px); gap: 12px; align-items: start; border: 1px solid var(--pi-border); border-radius: 10px; background: var(--pi-surface); padding: 10px 12px; }
    .setting-copy { display: grid; gap: 4px; min-width: 0; }
    .setting-copy strong { overflow-wrap: anywhere; }
    .setting-copy p { margin: 0; color: var(--pi-muted); font-size: 12px; }
    .setting-copy small { color: var(--pi-muted); }
    .setting-control { display: grid; gap: 4px; min-width: 0; }
    .setting-control input[type="text"], .setting-control input[type="number"], .setting-control select, .setting-control textarea { box-sizing: border-box; width: 100%; border: 1px solid var(--pi-border); border-radius: 8px; background: var(--pi-bg); color: var(--pi-text); padding: 6px 8px; font: inherit; }
    .setting-control textarea { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; resize: vertical; }
    .toggle { display: inline-flex; align-items: center; gap: 8px; }
    .json-error { color: var(--pi-danger); overflow-wrap: anywhere; }
    .save-bar { display: flex; justify-content: flex-end; }
    button { border: 1px solid var(--pi-border); border-radius: 8px; background: var(--pi-surface); color: var(--pi-text); padding: 7px 12px; font: inherit; cursor: pointer; }
    button:disabled { opacity: .55; cursor: not-allowed; }
    button.primary { border-color: var(--pi-accent); background: var(--pi-accent); color: var(--pi-accent-contrast, var(--pi-bg)); }
    button.secondary { background: var(--pi-surface); }

    @media (max-width: 760px) {
      .setting-row { grid-template-columns: minmax(0, 1fr); }
    }
  `;
}

declare global {
	interface HTMLElementTagNameMap {
		"settings-omp-panel": SettingsOmpPanel;
	}
}
