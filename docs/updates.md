# App updates

[Back to README](../README.md)

Fritz includes Sparkle 2.9.6. Open **Fritz → Settings… → General** to choose
**Release**, **Beta**, or **Staging**. Beta accepts beta and release items; Staging also
accepts staging items. Saved Dev selections migrate to Staging on launch. A configured
build checks for updates at startup, and **Fritz → Check for Updates** opens Sparkle's
update UI. A critical update blocks chat until it is installed. Settings also includes
Models, bundled Service status, and Debug.

## Build configuration

The source version is `0.1.1` in `Cargo.toml` and `app/project.yml`, with Sparkle build
number `2`. Release builds use those values by default. Ordinary local builds have no
update feed; distribution targets embed Fritz's Sparkle public key and the feed URL
configured in `scripts/release-config.sh`. The private key remains in the macOS Keychain
under the `fritz` Sparkle account.

## Publishing updates

`make staging` publishes a Staging update; `make beta` publishes a Beta update. Both use
the same pipeline, which builds the Developer ID signed app, creates and notarizes a
versioned DMG in `dist/updates/`, signs the selected channel’s appcast, and publishes
both through Fritz's own Cloudflare Worker and R2 bucket. Each run selects the next
unused patch version and build number from the source defaults, local artifacts, and
published appcast across all channels. `make publish-beta` and `make publish-staging`
retry prepared updates without rebuilding or notarizing. Staging updates are excluded
from the website download and cannot be promoted directly to Release. After testing a
Beta update, `make promote` publishes the same artifact on the Release channel by
updating the appcast. Explicit `FRITZ_VERSION` and `FRITZ_BUILD_NUMBER` overrides must
exceed existing versions and builds. See [the release procedure](agents/releases.md) for
one-time Cloudflare setup, credentials, and verification.

`make publish-beta`, `make publish-staging`, and `make promote` use the staged app's
version and build number, so version overrides used to build an update do not need to be
repeated for publication or promotion. Keep the staged app, DMG, and appcast together
until publication and promotion finish.

Beta and Release publications also appear on
[GitHub Releases](https://github.com/rel-me/fritz/releases), with the same notarized
DMG and a SHA-256 checksum. Beta entries are marked as prereleases; promotion
updates the same entry to a full Release. Staging updates remain on Fritz's
update service. See [the release procedure](agents/releases.md#github-releases).
