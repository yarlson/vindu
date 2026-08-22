const copyButtons = document.querySelectorAll("[data-copy-button]");

for (const button of copyButtons) {
  button.addEventListener("click", async () => {
    const commands = document.querySelector(button.dataset.copyTarget);
    const status = button.closest(".quick-start").querySelector("[data-copy-status]");

    try {
      if (!navigator.clipboard) {
        throw new Error("Clipboard access is unavailable");
      }
      await navigator.clipboard.writeText(commands.textContent.trim());
      button.textContent = "Copied";
      status.textContent = "Copied";
    } catch {
      button.textContent = "Copy install commands";
      status.textContent = "Copy failed. Select the commands and copy them.";
    }
  });
}
