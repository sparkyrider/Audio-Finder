import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const serviceWorkerSource = await readFile(
  new URL("../src/service_worker.js", import.meta.url),
  "utf8"
);
const manifest = JSON.parse(await readFile(
  new URL("../manifest.json", import.meta.url),
  "utf8"
));

const plain = (value) => JSON.parse(JSON.stringify(value));

function eventTarget() {
  return { addListener() {} };
}

function loadServiceWorker({
  tabs = [],
  stored = { browserChoice: "auto", sharingEnabled: true },
  isBrave = false
} = {}) {
  const fetchCalls = [];
  const storageWrites = [];
  const tabUpdates = [];
  const windowUpdates = [];
  const alarms = [];
  let tabQueryCount = 0;

  class FakeWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;

    constructor(url) {
      this.url = url;
      this.readyState = FakeWebSocket.CONNECTING;
    }

    close() {
      this.readyState = 3;
    }

    send() {}
  }

  const chrome = {
    runtime: {
      onInstalled: eventTarget(),
      onStartup: eventTarget(),
      onMessage: eventTarget(),
      openOptionsPage() {}
    },
    action: {
      onClicked: eventTarget()
    },
    alarms: {
      create(name, options) {
        alarms.push({ name, options });
      },
      onAlarm: eventTarget()
    },
    tabs: {
      onUpdated: eventTarget(),
      onRemoved: eventTarget(),
      onReplaced: eventTarget(),
      async query(query) {
        tabQueryCount += 1;
        assert.equal(query.audible, true);
        return tabs;
      },
      async get(tabID) {
        return tabs.find((tab) => tab.id === tabID) ?? { id: tabID };
      },
      async update(tabID, options) {
        tabUpdates.push({ tabID, options });
      }
    },
    windows: {
      onRemoved: eventTarget(),
      onFocusChanged: eventTarget(),
      async update(windowID, options) {
        windowUpdates.push({ windowID, options });
      }
    },
    storage: {
      onChanged: eventTarget(),
      local: {
        async get(defaults) {
          return { ...defaults, ...stored };
        },
        async set(value) {
          storageWrites.push(value);
        }
      }
    }
  };

  const context = vm.createContext({
    chrome,
    URLSearchParams,
    WebSocket: FakeWebSocket,
    navigator: {
      brave: {
        async isBrave() {
          return isBrave;
        }
      }
    },
    async fetch(url, options = {}) {
      fetchCalls.push({ url: String(url), options });
      if (options.method === "POST") {
        return { ok: true, status: 204 };
      }
      return {
        ok: true,
        status: 200,
        async json() {
          return { commands: [] };
        }
      };
    },
    setTimeout() {
      return 1;
    },
    clearTimeout() {},
    setInterval() {
      return 1;
    },
    clearInterval() {},
    console
  });

  vm.runInContext(serviceWorkerSource, context, {
    filename: "BrowserExtension/src/service_worker.js"
  });

  return {
    context,
    fetchCalls,
    storageWrites,
    tabUpdates,
    windowUpdates,
    alarms,
    get tabQueryCount() {
      return tabQueryCount;
    }
  };
}

test("posts only non-incognito audible tab metadata to the loopback bridge", async () => {
  const harness = loadServiceWorker({
    tabs: [
      {
        id: 11,
        windowId: 3,
        title: "Music",
        audible: true,
        incognito: false,
        mutedInfo: { muted: false },
        url: "https://example.com/private-url"
      },
      {
        id: 12,
        windowId: 4,
        title: "Private listening",
        audible: true,
        incognito: true,
        mutedInfo: { muted: false }
      },
      {
        id: undefined,
        windowId: 5,
        title: "Invalid tab",
        audible: true,
        incognito: false
      }
    ]
  });

  const result = await harness.context.sendAudibleTabs();
  const post = harness.fetchCalls.find((call) => call.options.method === "POST");
  const payload = JSON.parse(post.options.body);

  assert.deepEqual(plain(result), { ok: true, status: 204 });
  assert.equal(post.url, "http://127.0.0.1:17654/v1/browser-tabs");
  assert.deepEqual(payload, {
    browserBundleID: "com.google.Chrome",
    browserName: "Google Chrome",
    tabs: [
      {
        tabID: 11,
        windowID: 3,
        title: "Music",
        isMuted: false,
        isIncognito: false
      }
    ]
  });
  assert.equal(post.options.body.includes("private-url"), false);
  assert.equal(post.options.body.includes("Private listening"), false);
  assert.equal(harness.storageWrites.at(-1).lastStatus, "Connected");
});

test("uses the configured Brave identity and fixed production port", async () => {
  const harness = loadServiceWorker({
    stored: { browserChoice: "brave", port: 19000, sharingEnabled: true }
  });

  await harness.context.sendAudibleTabs();
  const post = harness.fetchCalls.find((call) => call.options.method === "POST");
  const payload = JSON.parse(post.options.body);

  assert.equal(post.url, "http://127.0.0.1:17654/v1/browser-tabs");
  assert.equal(payload.browserBundleID, "com.brave.Browser");
  assert.equal(payload.browserName, "Brave");
});

test("activates only valid tab commands", async () => {
  const harness = loadServiceWorker({
    tabs: [{ id: 33, windowId: 8, incognito: false }]
  });

  await harness.context.handleBrowserCommand({
    type: "activateTab",
    tabID: 33,
    windowID: 2
  });
  await harness.context.handleBrowserCommand({
    type: "activateTab",
    tabID: "not-a-number",
    windowID: 2
  });
  await harness.context.handleBrowserCommand({ type: "unknown" });

  assert.deepEqual(plain(harness.tabUpdates), [
    { tabID: 33, options: { active: true } }
  ]);
  assert.deepEqual(plain(harness.windowUpdates), [
    { windowID: 8, options: { focused: true } }
  ]);
});

test("requests a Chrome-supported 30-second heartbeat", () => {
  const harness = loadServiceWorker();

  assert.deepEqual(plain(harness.alarms[0]), {
    name: "audio-finder-heartbeat",
    options: { periodInMinutes: 0.5 }
  });
});

test("does not query or transmit tab data before explicit opt-in", async () => {
  const harness = loadServiceWorker({
    tabs: [{ id: 44, windowId: 9, title: "Must stay private", incognito: false }],
    stored: { browserChoice: "chrome", port: 17654, sharingEnabled: false }
  });

  const result = await harness.context.sendAudibleTabs();

  assert.deepEqual(plain(result), { ok: false, disabled: true });
  assert.equal(harness.tabQueryCount, 0);
  assert.equal(harness.fetchCalls.length, 0);
  assert.equal(harness.storageWrites.at(-1).lastStatus, "Connector disabled");
});

test("manifest disallows incognito operation and limits host access to the bridge", () => {
  assert.equal(manifest.incognito, "not_allowed");
  assert.deepEqual(manifest.host_permissions, ["http://127.0.0.1:17654/*"]);
});
