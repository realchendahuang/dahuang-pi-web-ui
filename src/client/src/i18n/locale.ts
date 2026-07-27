export const APP_LOCALES = ["zh", "en"] as const;
export type AppLocale = (typeof APP_LOCALES)[number];

export const DEFAULT_LOCALE: AppLocale = "zh";
export const LOCALE_STORAGE_KEY = "pi-web-app-locale";

export type LocaleStorage = Pick<Storage, "getItem" | "setItem">;

const listeners = new Set<() => void>();

let currentLocale: AppLocale = DEFAULT_LOCALE;
let storageBound = false;

export function parseAppLocale(
	value: string | null | undefined,
): AppLocale | undefined {
	if (value === "zh" || value === "en") return value;
	return undefined;
}

export function readStoredLocale(
	storage = browserStorage(),
): AppLocale | undefined {
	if (storage === undefined) return undefined;
	try {
		return parseAppLocale(storage.getItem(LOCALE_STORAGE_KEY));
	} catch {
		return undefined;
	}
}

export function writeStoredLocale(
	locale: AppLocale,
	storage = browserStorage(),
): void {
	if (storage === undefined) return;
	try {
		storage.setItem(LOCALE_STORAGE_KEY, locale);
	} catch {
		// Ignore quota/privacy errors; in-memory locale still applies for this tab.
	}
}

/** Active UI locale. Defaults to Chinese until a stored preference is loaded. */
export function getLocale(): AppLocale {
	ensureLocaleHydrated();
	return currentLocale;
}

export function setLocale(
	locale: AppLocale,
	options: { persist?: boolean; storage?: LocaleStorage } = {},
): void {
	ensureLocaleHydrated(options.storage);
	const next = parseAppLocale(locale) ?? DEFAULT_LOCALE;
	const changed = next !== currentLocale;
	currentLocale = next;
	if (options.persist !== false)
		writeStoredLocale(next, options.storage ?? browserStorage());
	applyDocumentLocale(next);
	if (changed) {
		for (const listener of listeners) listener();
	}
}

export function subscribeLocale(listener: () => void): () => void {
	listeners.add(listener);
	return () => {
		listeners.delete(listener);
	};
}

export function resetLocaleForTests(locale: AppLocale = DEFAULT_LOCALE): void {
	currentLocale = locale;
	storageBound = true;
	applyDocumentLocale(locale);
}

function ensureLocaleHydrated(storage = browserStorage()): void {
	if (storageBound) return;
	storageBound = true;
	currentLocale = readStoredLocale(storage) ?? DEFAULT_LOCALE;
	applyDocumentLocale(currentLocale);
}

function applyDocumentLocale(locale: AppLocale): void {
	if (typeof document === "undefined") return;
	document.documentElement.lang = locale === "zh" ? "zh-CN" : "en";
}

function browserStorage(): LocaleStorage | undefined {
	if (typeof window === "undefined") return undefined;
	try {
		return window.localStorage;
	} catch {
		return undefined;
	}
}
