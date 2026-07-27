import { afterEach, describe, expect, it } from "vitest";
import {
	DEFAULT_LOCALE,
	LOCALE_STORAGE_KEY,
	getLocale,
	parseAppLocale,
	readStoredLocale,
	resetLocaleForTests,
	setLocale,
	subscribeLocale,
	t,
	writeStoredLocale,
} from "./index";

afterEach(() => {
	resetLocaleForTests(DEFAULT_LOCALE);
});

describe("app locale preference", () => {
	it("defaults to Chinese", () => {
		expect(DEFAULT_LOCALE).toBe("zh");
		expect(parseAppLocale("nope")).toBeUndefined();
		expect(parseAppLocale("en")).toBe("en");
		expect(t("common.settings")).toBe("设置");
	});

	it("reads and writes locale preference from storage", () => {
		const store = memoryStorage();
		writeStoredLocale("en", store);
		expect(store.getItem(LOCALE_STORAGE_KEY)).toBe("en");
		expect(readStoredLocale(store)).toBe("en");
	});

	it("notifies subscribers when the locale changes", () => {
		const seen: string[] = [];
		const stop = subscribeLocale(() => {
			seen.push(getLocale());
		});
		setLocale("en", { persist: false });
		setLocale("en", { persist: false });
		setLocale("zh", { persist: false });
		stop();
		expect(seen).toEqual(["en", "zh"]);
		expect(t("common.settings")).toBe("设置");
		setLocale("en", { persist: false });
		expect(t("common.settings")).toBe("Settings");
	});

	it("interpolates message variables", () => {
		setLocale("en", { persist: false });
		expect(t("settings.general.description", { target: "Lab" })).toContain(
			"Lab",
		);
		setLocale("zh", { persist: false });
		expect(t("settings.packages.empty", { target: "本机" })).toBe(
			"本机 上尚未配置 Pi 包。",
		);
	});
});

function memoryStorage(): Storage {
	const data = new Map<string, string>();
	return {
		get length() {
			return data.size;
		},
		clear() {
			data.clear();
		},
		getItem(key: string) {
			return data.get(key) ?? null;
		},
		key(index: number) {
			return [...data.keys()][index] ?? null;
		},
		removeItem(key: string) {
			data.delete(key);
		},
		setItem(key: string, value: string) {
			data.set(key, value);
		},
	};
}
