const browserChoiceInput = document.getElementById("browserChoice");
const portInput = document.getElementById("port");
const statusText = document.getElementById("status");

document.getElementById("save").addEventListener("click", saveOptions);
document.getElementById("test").addEventListener("click", testBridge);

loadOptions();

async function loadOptions() {
  const stored = await chrome.storage.local.get({
    browserChoice: "auto",
    port: 17654,
    lastStatus: ""
  });

  browserChoiceInput.value = stored.browserChoice;
  portInput.value = stored.port;
  statusText.textContent = stored.lastStatus || "";
}

async function saveOptions() {
  await chrome.storage.local.set({
    browserChoice: browserChoiceInput.value,
    port: Number(portInput.value) || 17654
  });
  statusText.textContent = "Saved";
}

async function testBridge() {
  await saveOptions();
  statusText.textContent = "Testing...";
  const port = Number(portInput.value) || 17654;

  try {
    const statusResponse = await fetch(`http://127.0.0.1:${port}/v1/status`);
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
