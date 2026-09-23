// Shared by the Worker's /download route and the home page's version label.
const ARCHIVE_URL = /\/updates\/(Fritz-(\d+\.\d+\.\d+)\.dmg)$/;

// Returns the newest Release update, or the newest Beta while no Release exists.
export function latestDownload(appcast) {
  const items = [];
  for (const [, item] of appcast.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const channel = /<sparkle:channel>([^<]*)<\/sparkle:channel>/.exec(item)?.[1] ?? "release";
    const build = Number(/<sparkle:version>(\d+)<\/sparkle:version>/.exec(item)?.[1]);
    const url = /<enclosure\b[^>]*?\burl="([^"]+)"/.exec(item)?.[1] ?? "";
    const archive = ARCHIVE_URL.exec(url);
    if (archive && Number.isSafeInteger(build)) {
      items.push({ channel, build, filename: archive[1], version: archive[2] });
    }
  }
  for (const channel of ["release", "beta"]) {
    const [newest] = items.filter((item) => item.channel === channel).sort((a, b) => b.build - a.build);
    if (newest) return newest;
  }
  return null;
}
