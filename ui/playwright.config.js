import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './test', testMatch: '*.spec.js', fullyParallel: true, workers: 2,
  use: { baseURL: 'http://127.0.0.1:5173', channel: 'chrome', headless: true, screenshot: 'only-on-failure' },
  webServer: { command: 'npm run dev -- --port 5173', url: 'http://127.0.0.1:5173', reuseExistingServer: !process.env.CI },
});
