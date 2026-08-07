const browserChoiceInput = document.getElementById("browserChoice");
const sharingEnabledInput = document.getElementById("sharingEnabled");
const statusText = document.getElementById("status");
const bridgePort = 17654;

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
  try {
    const statusResponse = await fetch(`http://127.0.0.1:${bridgePort}/v1/status`);
    if (!statusResponse.ok) {
      statusText.textContent = `Bridge returned ${statusResponse.status}`;
      return;
    }
  } catch (error) {
    statusText.textContent = "Audio Finder is not reachable";
    return;
  }

  const result = await chrome.runtime.sendMessage({ type: "sendNow" });
  statusText.textContent = result?.ok ? "Connected" : (result?.error || "Connected");
}
