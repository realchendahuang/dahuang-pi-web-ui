import { getLocale, type AppLocale } from "./locale";
import { messageCatalog, type MessageKey } from "./messages";

export type MessageVars = Record<string, string | number | undefined>;

export function t(
	key: MessageKey,
	vars?: MessageVars,
	locale: AppLocale = getLocale(),
): string {
	const template = messageCatalog(locale)[key];
	if (vars === undefined) return template;
	return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name: string) => {
		const value = vars[name];
		return value === undefined ? match : String(value);
	});
}
