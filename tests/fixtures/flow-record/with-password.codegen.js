const { test, expect } = require('@playwright/test');

test('test', async ({ page }) => {
  await page.goto('https://example.com/login');
  await page.getByRole('textbox', { name: 'Email' }).fill('alice@example.com');
  await page.getByRole('textbox', { name: 'Password' }).fill('PWD-CANARY-9-1-iii');
  await page.getByRole('button', { name: 'Sign in' }).click();
});
