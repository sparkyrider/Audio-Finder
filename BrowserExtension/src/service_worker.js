const DEFAULT_PORT = 17654;
const HEARTBEAT_ALARM = "audio-finder-heartbeat";
const COMMAND_WAIT_SECONDS = 25;
const COMMAND_RETRY_MS = 250;
const BROWSER_CHOICES = {
  chrome: {
    browserBundleID: "com.google.Chrome",
    browserName: "Google Chrome"
  },
  brave: {
    browserBundleID: "com.brave.Browser",
    browserName: "Brave"
  }
};

let pendingSend = null;
let commandPollPromise = null;
let audibleTabCount = 0;

chrome.runtime.onInstalled.addListener(() => {
  ensureAlarms();
  queueSend();
});

chrome.runtime.onStartup.addListener(() => {
  ensureAlarms();
  queueSend();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === HEARTBEAT_ALARM) {
    queueSend();
  }
});

chrome.tabs.onUpdated.addListener((_tabId, changeInfo) => {
  if (
    Object.prototype.hasOwnProperty.call(changeInfo, "audible") ||
    Object.prototype.hasOwnProperty.call(changeInfo, "mutedInfo") ||
    Object.prototype.hasOwnProperty.call(changeInfo, "title")
  ) {
    queueSend();
  }
});

chrome.tabs.onRemoved.addListener(() => queueSend());
chrome.tabs.onReplaced.addListener(() => queueSend());
chrome.windows.onRemoved.addListener(() => queueSend());
chrome.windows.onFocusChanged.addListener(() => queueSend());
chrome.storage.onChanged.addListener((changes, area) => {
  if (
    area === "local" &&
    (
      Object.prototype.hasOwnProperty.call(changes, "browserChoice") ||
      Object.prototype.hasOwnProperty.call(changes, "port")
    )
  ) {
    queueSend();
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "sendNow") {
    return false;
  }

  sendAudibleTabs()
    .then((result) => sendResponse(result))
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});

ensureAlarms();
queueSend();

function ensureAlarms() {
  chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });
}

function queueSend() {
  if (pendingSend !== null) {
    clearTimeout(pendingSend);
  }

  pendingSend = setTimeout(() => {
    pendingSend = null;
    sendAudibleTabs();
  }, 250);
}

function startCommandPolling() {
  if (commandPollPromise !== null) {
    return commandPollPromise;
  }

  commandPollPromise = pollBrowserCommands()
    .catch(() => undefined)
    .finally(() => {
      commandPollPromise = null;
      if (audibleTabCount > 0) {
        setTimeout(startCommandPolling, COMMAND_RETRY_MS);
      }
    });

  return commandPollPromise;
}

async function pollBrowserCommands() {
  const options = await getOptions();
  const browser = await resolveBrowser(options.browserChoice);
  const params = new URLSearchParams({
    browserBundleID: browser.browserBundleID,
    wait: String(COMMAND_WAIT_SECONDS)
  });
  const response = await fetch(`http://127.0.0.1:${options.port}/v1/browser-commands?${params}`);

  if (!response.ok) {
    return;
  }

  const payload = await response.json();
  if (!Array.isArray(payload.commands)) {
    return;
  }

  for (const command of payload.commands) {
    await handleBrowserCommand(command);
  }
}

async function handleBrowserCommand(command) {
  if (command?.type !== "activateTab") {
    return;
  }

  const tabID = Number(command.tabID);
  const fallbackWindowID = Number(command.windowID);
  if (!Number.isInteger(tabID) || !Number.isInteger(fallbackWindowID)) {
    return;
  }

  try {
    const tab = await chrome.tabs.get(tabID);
    const windowID = Number.isInteger(tab.windowId) ? tab.windowId : fallbackWindowID;
    await chrome.tabs.update(tabID, { active: true });
    await chrome.windows.update(windowID, { focused: true });
    await sendAudibleTabs();
  } catch (_error) {
    queueSend();
  }
}

async function sendAudibleTabs() {
  const options = await getOptions();
  const browser = await resolveBrowser(options.browserChoice);
  const tabs = await chrome.tabs.query({ audible: true });
  const audibleTabs = tabs.filter((tab) => (
    typeof tab.id === "number" &&
    typeof tab.windowId === "number" &&
    !tab.incognito
  ));
  audibleTabCount = audibleTabs.length;

  const payload = {
    browserBundleID: browser.browserBundleID,
    browserName: browser.browserName,
    tabs: audibleTabs.map((tab) => ({
      tabID: tab.id,
      windowID: tab.windowId,
      title: tab.title || "Untitled tab",
      isMuted: Boolean(tab.mutedInfo?.muted),
      isIncognito: false
    }))
  };

  try {
    const response = await fetch(`http://127.0.0.1:${options.port}/v1/browser-tabs`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    });

    const ok = response.ok;
    await chrome.storage.local.set({
      lastStatus: ok ? "Connected" : `Bridge returned ${response.status}`,
      lastPostAt: Date.now()
    });
    if (ok && audibleTabCount > 0) {
      startCommandPolling();
    }
    return { ok, status: response.status };
  } catch (error) {
    await chrome.storage.local.set({
      lastStatus: "Audio Finder is not reachable",
      lastPostAt: Date.now()
    });
    return { ok: false, error: String(error) };
  }
}

async function getOptions() {
  const stored = await chrome.storage.local.get({
    browserChoice: "auto",
    port: DEFAULT_PORT
  });

  return {
    browserChoice: String(stored.browserChoice || "auto"),
    port: Number(stored.port) || DEFAULT_PORT
  };
}

async function resolveBrowser(choice) {
  if (choice === "chrome" || choice === "brave") {
    return BROWSER_CHOICES[choice];
  }

  try {
    if (globalThis.navigator?.brave && await globalThis.navigator.brave.isBrave()) {
      return BROWSER_CHOICES.brave;
    }
  } catch (_error) {
    // Fall through to Chrome. Brave users can choose Brave in extension options.
  }

  return BROWSER_CHOICES.chrome;
}
