import { cp, mkdir, rm } from "node:fs/promises";

// Copy the canonical identity on every build so the homepage follows branding updates.
const output = new URL("./.site/", import.meta.url);
await rm(output, { recursive: true, force: true });
await cp(new URL("./public/", import.meta.url), output, { recursive: true });
await mkdir(new URL("assets/", output), { recursive: true });
for (const name of ["FritzLogo.svg", "FritzLogoDark.svg", "FritzRaven.svg"]) {
  await cp(
    new URL(`../design/branding/${name}`, import.meta.url),
    new URL(`assets/${name}`, output),
  );
}
