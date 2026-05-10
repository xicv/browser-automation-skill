const { test, expect } = require('@playwright/test');

test('test', async ({ page }) => {
  await page.goto('https://example.com/users/new');
  await page.getByRole('textbox', { name: 'Email' }).fill('alice@example.com');
  await page.getByRole('button', { name: 'Sign in' }).click();
});
