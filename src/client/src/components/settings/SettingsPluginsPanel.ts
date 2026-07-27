import { css, html, LitElement, type TemplateResult } from "lit";
import { customElement, property } from "lit/decorators.js";
import type {
	PiWebConfigResponse,
	PiWebPluginInfo,
	PiWebPluginsResponse,
} from "../../api";
import { LocaleController, t } from "../../i18n";
import "./SettingsPanelFrame";
import type { SettingsNotice } from "./SettingsPanelFrame";

@customElement("settings-plugins-panel")
export class SettingsPluginsPanel extends LitElement {
	@property({ attribute: false }) pluginsResponse:
		| PiWebPluginsResponse
		| undefined;
	@property({ attribute: false }) configResponse:
		| PiWebConfigResponse
		| undefined;
	@property({ type: Boolean }) loading = false;
	@property({ type: Boolean }) saving = false;
	@property() error = "";
	@property() savedMessage = "";
	@property() targetLabel = "local (local gateway)";
	@property({ attribute: false }) onReload?: () => void | Promise<void>;
	@property({ attribute: false }) onTogglePlugin?: (
		pluginId: string,
		enabled: boolean,
	) => void | Promise<void>;
	private readonly locale = new LocaleController(this);

	override render(): TemplateResult {
		void this.locale.locale;
		const plugins = this.pluginsResponse?.plugins ?? [];
		const hasPluginResponse = this.pluginsResponse !== undefined;
		return html`
      <settings-panel-frame
        heading=${t("settings.plugins.heading")}
        .description=${pluginsDescription(this.targetLabel)}
        actionLabel=${t("common.reload")}
        actionTitle=${t("settings.plugins.description", { target: this.targetLabel })}
        .actionDisabled=${this.loading}
        .notices=${this.panelNotices(plugins.length > 0)}
        .onAction=${this.onReload}
      >
        ${this.renderPanelContent(plugins, hasPluginResponse)}
      </settings-panel-frame>
    `;
	}

	private panelNotices(
		showTrustedCodeWarning: boolean,
	): readonly SettingsNotice[] {
		const notices: SettingsNotice[] = [];
		if (this.error !== "") notices.push({ type: "error", content: this.error });
		if (this.shouldShowConfigUnavailableNotice(showTrustedCodeWarning)) {
			notices.push({
				type: "availability",
				content: t("settings.sessiond.unavailable"),
			});
		}
		if (this.savedMessage !== "")
			notices.push({ type: "success", content: this.savedMessage });
		if (showTrustedCodeWarning) {
			notices.push({
				type: "security",
				content: t("settings.plugins.trustWarning"),
			});
		}
		return notices;
	}

	private shouldShowConfigUnavailableNotice(
		hasLoadedPlugins: boolean,
	): boolean {
		return (
			hasLoadedPlugins &&
			this.configResponse === undefined &&
			!this.loading &&
			this.error === ""
		);
	}

	private renderPanelContent(
		plugins: PiWebPluginInfo[],
		hasPluginResponse: boolean,
	): TemplateResult {
		if (!hasPluginResponse) {
			return html`<div class="loading-card">${this.loading ? t("settings.plugins.loading") : t("settings.plugins.listUnavailable", { target: this.targetLabel })}</div>`;
		}
		if (plugins.length === 0) {
			return html`<div class="loading-card">${t("settings.plugins.empty", { target: this.targetLabel })}</div>`;
		}
		return html`
      <div class="plugin-note"><code>plugins</code> · ${this.targetLabel}</div>
      <div class="plugin-list">
        ${plugins.map((plugin) => this.renderPlugin(plugin))}
      </div>
    `;
	}

	private renderPlugin(plugin: PiWebPluginInfo): TemplateResult {
		const configured = this.configResponse?.config.plugins?.[plugin.id];
		const configuredState =
			configured?.enabled === false
				? "Config disabled"
				: configured?.enabled === true
					? "Config enabled"
					: "Default enabled";
		return html`
      <article class=${`plugin-card${plugin.enabled ? "" : " disabled"}`}>
        <div class="plugin-main">
          <strong>${plugin.id}</strong>
          <small>${plugin.source} · ${plugin.scope}${plugin.machineSpecific ? " · machine-specific" : ""}</small>
          <small>${configuredState}</small>
        </div>
        <label class="toggle">
          <input type="checkbox" .checked=${plugin.enabled} ?disabled=${this.saving || this.configResponse === undefined} @change=${(
						event: Event,
					) => {
						void this.togglePlugin(plugin, event);
					}}>
          <span>${plugin.enabled ? t("common.enabled") : t("common.disabled")}</span>
        </label>
      </article>
    `;
	}

	private async togglePlugin(
		plugin: PiWebPluginInfo,
		event: Event,
	): Promise<void> {
		const enabled =
			event.target instanceof HTMLInputElement
				? event.target.checked
				: plugin.enabled;
		await this.onTogglePlugin?.(plugin.id, enabled);
	}

	static override styles = css`
    :host { display: block; }
    input { font: inherit; }
    input:disabled { opacity: .55; cursor: not-allowed; }
    .loading-card, .plugin-note, .plugin-card { border: 1px solid var(--pi-border); border-radius: 10px; background: var(--pi-surface); padding: 12px; }
    .loading-card, .plugin-note { color: var(--pi-muted); }
    code { border: 1px solid var(--pi-border-muted); border-radius: 5px; background: var(--pi-bg); padding: 1px 4px; color: var(--pi-text); font: 12px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; overflow-wrap: anywhere; }
    .plugin-list { display: grid; gap: 10px; }
    .plugin-card { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 12px; align-items: center; }
    .plugin-card.disabled { opacity: .75; }
    .plugin-main { min-width: 0; display: grid; gap: 3px; }
    .plugin-main strong, .plugin-main small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .plugin-main small { color: var(--pi-muted); }
    .toggle { display: inline-flex; align-items: center; gap: 7px; white-space: nowrap; }
    .toggle input { width: 18px; height: 18px; accent-color: var(--pi-accent); }

    @media (max-width: 760px) {
      .plugin-card { grid-template-columns: minmax(0, 1fr); align-items: start; }
      .toggle { justify-self: start; }
    }
  `;
}

function pluginsDescription(targetLabel: string): string {
	return t("settings.plugins.description", { target: targetLabel });
}
