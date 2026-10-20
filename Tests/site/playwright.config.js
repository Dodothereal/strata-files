const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({
  testDir: '.',
  testMatch: '*.spec.js',
  timeout: 30000,
  use: {
    baseURL: process.env.SITE_TEST_URL || 'http://127.0.0.1:8765',
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {},
  },
  webServer: process.env.SITE_TEST_URL ? undefined : {
    command: 'python3 -m http.server 8765 --bind 127.0.0.1 --directory ../../build/site',
    url: 'http://127.0.0.1:8765', reuseExistingServer: false,
  },
});
