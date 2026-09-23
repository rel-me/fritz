const buttons = document.querySelectorAll("[data-select-mode]");
const previews = document.querySelectorAll("[data-mode]");
const description = document.querySelector("#mode-description");
for (const button of buttons) {
  button.addEventListener("click", () => {
    const mode = button.dataset.selectMode;
    for (const toggle of buttons)
      toggle.setAttribute("aria-pressed", String(toggle === button));
    for (const preview of previews)
      preview.hidden = preview.dataset.mode !== mode;
    description.textContent =
      mode === "chat"
        ? "Think it through in Chat. Make it happen in Code."
        : "Read files, make edits, and run commands in your project.";
  });
}
