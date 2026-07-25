async (page) => {
	await page.goto("http://localhost:8505/");
	await page.waitForTimeout(2500);
	const project = page.locator("text=/dahuang-pi-web-ui/").first();
	if (await project.count()) {
		await project.click();
		await page.waitForTimeout(1200);
	}
	const workspace = page.locator("text=/ui-rebuild · main/").first();
	if (await workspace.count()) {
		await workspace.click();
		await page.waitForTimeout(2000);
	}
	const session = page.locator("session-list").locator(".action-row").first();
	if (await session.count()) {
		await session.click();
		await page.waitForTimeout(3500);
	}
};
