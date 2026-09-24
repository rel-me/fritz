# Fritz releases

Fritz's release identity uses bundle ID `dev.fritz.app`, Sparkle Keychain
account `fritz`, the custom domain configured in `website/wrangler.jsonc`,
and R2 bucket `fritz-updates`. The Apple notarization profile is configured
through `FRITZ_NOTARY_PROFILE` in `scripts/release-config.sh`.

## One-time setup

The public Sparkle key is in `scripts/release-config.sh`. Its private half was
generated with the pinned Sparkle `generate_keys --account fritz` tool and stays
in this macOS user's Keychain. To inspect the public key on this machine:

```sh
dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account fritz -p
```

Set up Cloudflare access with `cd website && npx wrangler login` in an
interactive terminal, or supply `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` for Wrangler. Create the dedicated bucket once:

```sh
cd website
npm ci
npx wrangler r2 bucket create fritz-updates
```

The first `make beta` deploys `website/worker.mjs` to the custom domain in
`website/wrangler.jsonc`. The Cloudflare account must own the configured zone and
permit custom domains for Workers. Confirm the configured hostname resolves
after that deployment. The Worker serves the appcast from R2 with `no-store` and
versioned DMGs with immutable caching and byte-range support.

## Home page

The home page is static: `website/public/` is published as the Worker's static
assets, which answer before the Worker code. `_headers` sets its Content
Security Policy, so keep scripts and styles in separate files. `/download`
redirects to the newest Release DMG in the appcast, or the newest Beta before a
Release exists; the page reads the same appcast to label the version. The raven,
favicon, touch icon, and social card come from `design/branding/export.py`.

`make beta`, `make publish-beta`, and `make promote` deploy the current page
with the Worker. Run `npm --prefix website test` after editing it. To preview
locally, seed the local bucket and start Wrangler; nothing is uploaded:

```sh
cd website
npx wrangler r2 object put fritz-updates/appcast.xml --local --file=../dist/updates/appcast.xml
npx wrangler dev --local
```

`FRITZ_CODE_SIGN_IDENTITY` defaults to the Fritz team's Developer ID
Application certificate. Check access to the configured notarization profile
before building:

```sh
FRITZ_DISTRIBUTION=1
source scripts/release-config.sh
xcrun notarytool history --keychain-profile "$FRITZ_NOTARY_PROFILE"
```

## Beta and promotion

Keep `Cargo.toml`, `Cargo.lock`, `app/project.yml`, and the generated Xcode
project at the same app version. Increase `CURRENT_PROJECT_VERSION` on each
published build. Run the affected tests and stage a Release app first:

```sh
make test
make check
CONFIGURATION=release make build
make beta
```

`make beta` reads the source version and build number. It verifies notarization
credentials before building, refuses to replace an existing local versioned
DMG, then builds, notarizes, staples, signs the appcast, deploys the Worker,
uploads the DMG and appcast to the separate bucket, and checks the live URLs.
An interrupted upload can be retried with `make beta` or `make publish-beta`
after the local archive and appcast have been prepared. Test the Beta update channel before
running `make promote`. Promotion changes the appcast channel and uploads it;
the DMG is not rebuilt or uploaded again.

Release defaults in `scripts/release-config.sh` can be overridden through
`FRITZ_VERSION`, `FRITZ_BUILD_NUMBER`, `FRITZ_CODE_SIGN_IDENTITY`,
`FRITZ_NOTARY_PROFILE`, `FRITZ_SPARKLE_FEED_URL`,
`FRITZ_SPARKLE_PUBLIC_ED_KEY`, `FRITZ_UPDATE_DOWNLOAD_URL_PREFIX`, and
`FRITZ_HOMEPAGE_URL`. If the hostname changes, update the Worker custom domain
and `FRITZ_RELEASE_BASE_URL` together. The private Sparkle key is never placed
in the repository, an environment variable, or the app bundle.
