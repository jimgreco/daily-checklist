const { defineConfig, devices } = require("@playwright/test");
const os = require("node:os");
const path = require("node:path");

const port = Number(process.env.PLAYWRIGHT_PORT || 8787);
const baseURL = `http://127.0.0.1:${port}`;
const dataFile = process.env.PLAYWRIGHT_DATA_FILE
  || path.join(os.tmpdir(), `ritual-cue-playwright-${port}.json`);

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

const prepareDataFile = [
  'const fs=require("node:fs");',
  'const path=require("node:path");',
  `const file=${JSON.stringify(dataFile)};`,
  'fs.mkdirSync(path.dirname(file),{recursive:true});',
  'fs.rmSync(file,{force:true});'
].join(" ");

module.exports = defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  workers: 1,
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL,
    acceptDownloads: true,
    screenshot: "only-on-failure",
    trace: "retain-on-failure"
  },
  webServer: {
    command: [
      `node -e ${shellQuote(prepareDataFile)}`,
      `DATA_FILE=${shellQuote(dataFile)} PORT=${port} NODE_ENV=test node src/server.js`
    ].join(" && "),
    url: `${baseURL}/health`,
    reuseExistingServer: false,
    timeout: 15_000
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] }
    }
  ]
});
