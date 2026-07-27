export {
	APP_LOCALES,
	DEFAULT_LOCALE,
	LOCALE_STORAGE_KEY,
	getLocale,
	parseAppLocale,
	readStoredLocale,
	resetLocaleForTests,
	setLocale,
	subscribeLocale,
	writeStoredLocale,
	type AppLocale,
	type LocaleStorage,
} from "./locale";
export {
	localizeActionLabels,
	localizePanelTitle,
	type LocalizableAction,
} from "./actionLabels";
export { LocaleController } from "./localeController";
export {
	enMessages,
	messageCatalog,
	zhMessages,
	type MessageKey,
} from "./messages";
export { t, type MessageVars } from "./t";
