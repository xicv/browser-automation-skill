const { test, expect } = require('@playwright/test');

test('test', async ({ page }) => {
  await page.goto('https://example.com/');
  await page.locator('xpath=//div[@class="custom"]').click();
});
