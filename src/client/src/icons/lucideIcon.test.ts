import { describe, expect, it } from "vitest";
import { Settings, Send } from "lucide";
import { appIcon } from "./appIcons";
import { renderLucideIcon } from "./lucideIcon";

describe("lucide icons", () => {
	it("renders lucide nodes into a lit SVG template", () => {
		const icon = renderLucideIcon(Settings, {
			className: "test-icon",
			size: 18,
		});
		expect(icon.strings.join("")).toContain('viewBox="0 0 24 24"');
		expect(icon.values).toContain("test-icon");
		expect(icon.values).toContain("18");
	});

	it("exposes named app icons used by chrome", () => {
		const settings = appIcon("settings");
		const send = appIcon("send");
		expect(settings.strings.join("")).toContain("svg");
		expect(send.strings.join("")).toContain("svg");
		// Smoke: underlying lucide nodes exist
		expect(Settings.length).toBeGreaterThan(0);
		expect(Send.length).toBeGreaterThan(0);
	});
});
