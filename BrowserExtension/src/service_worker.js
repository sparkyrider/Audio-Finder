const DEFAULT_PORT = 17654;
const HEARTBEAT_ALARM = "audio-finder-heartbeat";
const COMMAND_WAIT_SECONDS = 10;
const COMMAND_RETRY_MS = 250;
const COMMAND_IDLE_GRACE_MS = 2 * 60 * 1000;
const COMMAND_SOCKET_KEEPALIVE_MS = 20 * 1000;
const COMMAND_SOCKET_RECONNECT_MS = 1000;
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
let commandSocket = null;
let commandSocketKeepAlive = null;
let commandSocketReconnect = null;
let audibleTabCount = 0;
let commandPollingUntil = 0;

chrome.runtime.onInstalled.addListener((details) => {
  ensureAlarms();
  queueSend();
  if (details.reason === "install") {
    chrome.runtime.openOptionsPage();
  }
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
      Object.prototype.hasOwnProperty.call(changes, "sharingEnabled")
    )
  ) {
    disconnectCommandSocket();
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

chrome.action.onClicked.addListener(() => {
  chrome.runtime.openOptionsPage();
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
      if (shouldKeepPollingCommands()) {
        setTimeout(startCommandPolling, COMMAND_RETRY_MS);
      }
    });

  return commandPollPromise;
}

function shouldKeepPollingCommands() {
  return Date.now() < commandPollingUntil;
}

function startCommandChannel() {
  commandPollingUntil = Date.now() + COMMAND_IDLE_GRACE_MS;
  connectCommandSocket();
  startCommandPolling();
}

async function connectCommandSocket() {
  if (!shouldKeepPollingCommands()) {
    return;
  }

  if (
    commandSocket !== null &&
    (commandSocket.readyState === WebSocket.CONNECTING || commandSocket.readyState === WebSocket.OPEN)
  ) {
    return;
  }

  if (commandSocketReconnect !== null) {
    clearTimeout(commandSocketReconnect);
    commandSocketReconnect = null;
  }

  const options = await getOptions();
  const browser = await resolveBrowser(options.browserChoice);
  const params = new URLSearchParams({
    browserBundleID: browser.browserBundleID
  });
  const socket = new WebSocket(`ws://127.0.0.1:${DEFAULT_PORT}/v1/browser-command-stream?${params}`);
  commandSocket = socket;

  socket.onopen = () => {
    startCommandSocketKeepAlive(socket);
  };

  socket.onmessage = (event) => {
    handleBrowserCommandPayload(event.data).catch(() => undefined);
  };

  socket.onerror = () => {
    startCommandPolling();
    if (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN) {
      socket.close();
    }
  };

  socket.onclose = () => {
    if (commandSocket === socket) {
      commandSocket = null;
    }
    stopCommandSocketKeepAlive(socket);
    scheduleCommandSocketReconnect();
  };
}

function startCommandSocketKeepAlive(socket) {
  stopCommandSocketKeepAlive();
  commandSocketKeepAlive = setInterval(() => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send("keepalive");
    } else {
      stopCommandSocketKeepAlive(socket);
    }
  }, COMMAND_SOCKET_KEEPALIVE_MS);
}

function stopCommandSocketKeepAlive(socket = null) {
  if (socket !== null && commandSocket !== null && socket !== commandSocket) {
    return;
  }

  if (commandSocketKeepAlive !== null) {
    clearInterval(commandSocketKeepAlive);
    commandSocketKeepAlive = null;
  }
}

function scheduleCommandSocketReconnect() {
  if (!shouldKeepPollingCommands() || commandSocketReconnect !== null) {
    return;
  }

  commandSocketReconnect = setTimeout(() => {
    commandSocketReconnect = null;
    connectCommandSocket();
  }, COMMAND_SOCKET_RECONNECT_MS);
}

function disconnectCommandSocket() {
  if (commandSocketReconnect !== null) {
    clearTimeout(commandSocketReconnect);
    commandSocketReconnect = null;
  }
  stopCommandSocketKeepAlive();

  if (commandSocket !== null) {
    const socket = commandSocket;
    commandSocket = null;
    socket.close();
  }
}

async function pollBrowserCommands() {
  const options = await getOptions();
  const browser = await resolveBrowser(options.browserChoice);
  const params = new URLSearchParams({
    browserBundleID: browser.browserBundleID,
    wait: String(COMMAND_WAIT_SECONDS)
  });
  const response = await fetch(`http://127.0.0.1:${DEFAULT_PORT}/v1/browser-commands?${params}`);

  if (!response.ok) {
    return;
  }

  const payload = await response.json();
  if (!Array.isArray(payload.commands)) {
    return;
  }

  await handleBrowserCommands(payload.commands);
}

async function handleBrowserCommandPayload(data) {
  const payload = typeof data === "string" ? JSON.parse(data) : data;
  const commands = Array.isArray(payload?.commands) ? payload.commands : [payload];
  await handleBrowserCommands(commands);
}

async function handleBrowserCommands(commands) {
  for (const command of commands) {
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
  if (!options.sharingEnabled) {
    audibleTabCount = 0;
    commandPollingUntil = 0;
    disconnectCommandSocket();
    await chrome.storage.local.set({
      lastStatus: "Connector disabled",
      lastPostAt: Date.now()
    });
    return { ok: false, disabled: true };
  }

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
    const response = await fetch(`http://127.0.0.1:${DEFAULT_PORT}/v1/browser-tabs`, {
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
      startCommandChannel();
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
    sharingEnabled: false
  });

  return {
    browserChoice: String(stored.browserChoice || "auto"),
    sharingEnabled: stored.sharingEnabled === true
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
