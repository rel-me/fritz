import { latestDownload } from "/appcast.mjs";

// Hidden-until-visible styles apply only once this script is running.
document.documentElement.classList.add("reveal");

const observer = "IntersectionObserver" in window && new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add("is-visible");
    observer.unobserve(entry.target);
  }
}, { threshold: 0.2 });

for (const element of document.querySelectorAll("[data-reveal]")) {
  if (observer) observer.observe(element);
  else element.classList.add("is-visible");
}

const formatSize = (bytes) => `${(bytes / 1_000_000).toFixed(1)} MB`;

async function showDefaultDownload() {
  const response = await fetch("/appcast.xml", { cache: "no-store" });
  const latest = response.ok && latestDownload(await response.text());
  if (latest) {
    const channel = latest.channel === "release" ? "" : ` ${latest.channel}`;
    const size = latest.bytes ? ` · ${formatSize(latest.bytes)}` : "";
    for (const element of document.querySelectorAll("[data-version]")) {
      element.textContent = `Version ${latest.version}${channel}${size} · Requires macOS 15 or later.`;
    }
    for (const link of document.querySelectorAll("[data-download]")) {
      link.href = `/updates/${latest.filename}`;
    }
  }
}

async function showChromiumDownload() {
  const response = await fetch("/chromium-download.json", { cache: "no-store" });
  if (!response.ok) return;
  const { version, archive, bytes } = await response.json();
  const download = document.querySelector("[data-chromium-download]");
  const label = document.querySelector("[data-chromium-version]");
  if (!download || !label) return;
  download.href = archive;
  label.textContent = `Version ${version} · ${formatSize(bytes)} · Requires macOS 15 or later.`;
  download.hidden = false;
  label.hidden = false;
}

// Keep the default download and source build links available if metadata is offline.
await Promise.allSettled([showDefaultDownload(), showChromiumDownload()]);
