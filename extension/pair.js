const status = document.getElementById("status");
chrome.storage.local.get("pairingKey", ({ pairingKey }) => {
  if (pairingKey) status.textContent = "Pairing key saved. Re-pair here if you change Macs.";
});
document.getElementById("pair").addEventListener("submit", async (event) => {
  event.preventDefault();
  const pairingKey = document.getElementById("key").value.trim();
  if (!/^[a-f0-9]{64}$/.test(pairingKey)) { status.textContent = "Paste the complete key from Agent HUD."; return; }
  try {
    const response = await fetch("http://127.0.0.1:48085/health", {
      headers: { "X-Agent-HUD-Token": pairingKey, "X-Agent-HUD-Client": "browser" },
    });
    if (!response.ok) throw new Error("Pairing key was rejected. Copy it again from Agent HUD.");
    chrome.storage.local.set({ pairingKey }, () => {
      document.getElementById("key").value = "";
      status.textContent = "Paired. Reload your chat and music tabs to connect.";
    });
  } catch (error) { status.textContent = error.message || "Open Agent HUD and try again."; }
});
