import { t, type MessageKey } from "./index";

interface ActionLabelSpec {
	title: MessageKey;
	description?: MessageKey;
	group?: MessageKey;
}

/** Maps core plugin local action ids to message keys. */
const CORE_ACTION_LABELS: Record<string, ActionLabelSpec> = {
	"actions.show": {
		title: "action.actionsShow",
		description: "action.actionsShowDesc",
		group: "group.general",
	},
	"prompt.focus": {
		title: "action.promptFocus",
		description: "action.promptFocusDesc",
		group: "group.general",
	},
	"machine.add": {
		title: "action.machineAdd",
		description: "action.machineAddDesc",
		group: "group.machine",
	},
	"machine.refresh": {
		title: "action.machineRefresh",
		description: "action.machineRefreshDesc",
		group: "group.machine",
	},
	"machine.open": {
		title: "action.machineOpen",
		description: "action.machineOpenDesc",
		group: "group.machine",
	},
	"machine.remove": {
		title: "action.machineRemove",
		description: "action.machineRemoveDesc",
		group: "group.machine",
	},
	"project.add": { title: "action.projectAdd", group: "group.project" },
	"auth.login": {
		title: "action.authLogin",
		description: "action.authLoginDesc",
		group: "group.general",
	},
	"auth.logout": {
		title: "action.authLogout",
		description: "action.authLogoutDesc",
		group: "group.general",
	},
	"theme.select": {
		title: "action.themeSelect",
		description: "action.themeSelectDesc",
		group: "group.preferences",
	},
	"settings.open": {
		title: "action.settingsOpen",
		description: "action.settingsOpenDesc",
		group: "group.preferences",
	},
	"app.reload-page": {
		title: "action.reloadPage",
		description: "action.reloadPageDesc",
		group: "group.general",
	},
	"view.chat": { title: "action.viewChat", group: "group.navigation" },
	"view.files": { title: "action.viewFiles", group: "group.navigation" },
	"view.git": { title: "action.viewGit", group: "group.navigation" },
	"view.terminal": { title: "action.viewTerminal", group: "group.navigation" },
	"workspace.refresh-files": {
		title: "action.refreshFiles",
		group: "group.workspace",
	},
	"workspace.refresh-git": {
		title: "action.refreshGit",
		group: "group.workspace",
	},
	"workspace.refresh-current": {
		title: "action.refreshCurrent",
		group: "group.workspace",
	},
	"workspace.delete": {
		title: "action.workspaceDelete",
		description: "action.workspaceDeleteDesc",
		group: "group.workspace",
	},
	"session.start": { title: "action.sessionStart", group: "group.session" },
	"session.archive": {
		title: "action.sessionArchive",
		description: "action.sessionArchiveDesc",
		group: "group.session",
	},
	"session.reload": {
		title: "action.sessionReload",
		description: "action.sessionReloadDesc",
		group: "group.session",
	},
	"session.delete": {
		title: "action.sessionDelete",
		description: "action.sessionDeleteDesc",
		group: "group.session",
	},
	"session.stop": { title: "action.sessionStop", group: "group.session" },
};

export interface LocalizableAction {
	id: string;
	localId?: string;
	title: string;
	description?: string;
	group?: string;
}

export function localizeActionLabels<T extends LocalizableAction>(
	action: T,
): T {
	const localId = action.localId ?? stripPluginPrefix(action.id);
	const spec = CORE_ACTION_LABELS[localId];
	if (spec === undefined) return action;
	const next: T = {
		...action,
		title: t(spec.title),
	};
	if (spec.description !== undefined) next.description = t(spec.description);
	if (spec.group !== undefined) next.group = t(spec.group);
	return next;
}

const CORE_PANEL_TITLES: Record<string, MessageKey> = {
	"workspace.changes": "panel.changes",
	"workspace.files": "panel.files",
	"workspace.git": "panel.git",
	"workspace.terminal": "panel.terminal",
	"workspace.context": "panel.context",
};

export function localizePanelTitle(localId: string, fallback: string): string {
	const key = CORE_PANEL_TITLES[localId];
	return key === undefined ? fallback : t(key);
}

function stripPluginPrefix(id: string): string {
	const index = id.indexOf(":");
	return index === -1 ? id : id.slice(index + 1);
}
