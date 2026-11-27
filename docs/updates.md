# App updates

[Back to README](../README.md)

Fritz includes Sparkle 2.10.1. Open **Fritz → Settings… → General** to choose
**Release**, **Beta**, or **Staging**. Beta accepts beta and release items; Staging also
accepts staging items. Saved Dev selections migrate to Staging on launch. Sparkle
checks for updates in the background on configured builds. The workspace opens
immediately and stays available when an update is found, including critical updates.
**Fritz → Check for Updates** opens Sparkle's update UI. Settings also includes
Models, bundled Service status, and Debug.

## Build configuration

The source version is `0.1.1` in `Cargo.toml` and `app/project.yml`, with Sparkle build
number `2`. Release builds use those values by default. Ordinary local builds have no
update feed; distribution targets embed Fritz's Sparkle public key and the feed URL
configured in `scripts/release-config.sh`. The private key remains in the macOS Keychain
under the `fritz` Sparkle account.

## Publishing updates

`make beta` publishes successive Betas such as `0.1.23-beta.1` and
`0.1.23-beta.2`. `make staging` uses its own suffix, such as
`0.1.23-staging.1`. Build numbers increase across all channels.

After testing a Beta, run `make promote` to build the base version of the
latest published Beta for the Release channel. For example, `0.1.23-beta.2`
becomes `0.1.23` with a higher build number. The following Beta starts at
`0.1.24-beta.1`.

Beta and Release have separate entries on
[GitHub Releases](https://github.com/rel-me/fritz/releases), each with its
notarized DMG and SHA-256 checksum. Staging stays on Fritz's update service.
Use `make publish-beta`, `make publish-staging`, or `make publish-release`
to retry publication of a prepared update. See the
[release procedure](agents/releases.md) for credentials and verification.
