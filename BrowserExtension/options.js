const browserChoiceInput = document.getElementById("browserChoice");
const sharingEnabledInput = document.getElementById("sharingEnabled");
const statusText = document.getElementById("status");
const BRIDGE_PORTS = [17654, 17655];

document.getElementById("save").addEventListener("click", saveOptions);
document.getElementById("test").addEventListener("click", testBridge);

loadOptions();

async function loadOptions() {
  const stored = await chrome.storage.local.get({
    browserChoice: "auto",
    sharingEnabled: false,
    lastStatus: ""
  });

  browserChoiceInput.value = stored.browserChoice;
  sharingEnabledInput.checked = stored.sharingEnabled === true;
  statusText.textContent = stored.lastStatus || "";
}

async function saveOptions() {
  await chrome.storage.local.set({
    browserChoice: browserChoiceInput.value,
    sharingEnabled: sharingEnabledInput.checked
  });
  statusText.textContent = sharingEnabledInput.checked
    ? "Saved. Connector enabled."
    : "Saved. Connector disabled.";
}

async function testBridge() {
  await saveOptions();
  if (!sharingEnabledInput.checked) {
    statusText.textContent = "Enable the connector before testing.";
    return;
  }

  statusText.textContent = "Testing...";
  const port = await findBridgePort();
  if (port === null) {
    statusText.textContent = "Audio Finder is not reachable";
    return;
  }

  const result = await chrome.runtime.sendMessage({ type: "sendNow" });
  statusText.textContent = result?.ok
    ? `Connected on port ${result.port || port}`
    : (result?.error || "Audio Finder is not reachable");
}

async function findBridgePort() {
  for (const port of BRIDGE_PORTS) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/v1/status`);
      if (!response.ok) {
        continue;
      }

      const status = await response.json();
      if (status?.ok === true && status?.app === "Audio Finder") {
        return port;
      }
    } catch (_error) {
      // Try the backup port.
    }
  }

  return null;
}
