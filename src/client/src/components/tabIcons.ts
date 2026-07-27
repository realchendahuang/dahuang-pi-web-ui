import { html, type TemplateResult } from "lit";
import { appIcon } from "../icons/appIcons";

export type AppTabBuiltinIcon =
	| "navigation"
	| "chat"
	| "files"
	| "git"
	| "terminal"
	| "changes"
	| "context";
export type AppTabIcon = AppTabBuiltinIcon | TemplateResult;

export function renderAppTabIcon(icon: AppTabIcon): TemplateResult {
	if (typeof icon !== "string")
		return html`<span class="tab-custom-icon" aria-hidden="true">${icon}</span>`;
	return renderBuiltinTabIcon(icon);
}

export function renderBuiltinTabIcon(icon: AppTabBuiltinIcon): TemplateResult {
	const className = "tab-icon lucide-icon";
	switch (icon) {
		case "navigation":
			return appIcon("list", { className, size: 16 });
		case "chat":
			return appIcon("message", { className, size: 16 });
		case "files":
			return appIcon("folder", { className, size: 16 });
		case "git":
			return appIcon("git", { className, size: 16 });
		case "terminal":
			return appIcon("terminal", { className, size: 16 });
		case "changes":
			return appIcon("diff", { className, size: 16 });
		case "context":
			return appIcon("context", { className, size: 16 });
	}
}
