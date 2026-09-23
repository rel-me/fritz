# Fritz releases

Fritz has its own release identity: bundle ID `dev.fritz.app`, Sparkle Keychain
account `fritz`, custom domain `fritz.rel.me`, and R2 bucket `fritz-updates`.
REL's update key, website, bucket, and appcast are not used. The same Apple
Developer team may notarize both apps; `FRITZ_NOTARY_PROFILE` defaults to the
existing `REL` notarytool profile and can be overridden.

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
`website/wrangler.jsonc`. The Cloudflare account must own the `rel.me` zone and
permit custom domains for Workers. Confirm `https://fritz.rel.me` resolves
after that deployment. The Worker serves the appcast from R2 with `no-store` and
versioned DMGs with immutable caching and byte-range support.

`FRITZ_CODE_SIGN_IDENTITY` defaults to the Fritz team's Developer ID
Application certificate. `FRITZ_NOTARY_PROFILE` defaults to `REL`, which is an
Apple notarization credential, not a REL app credential. Check access before
building:

```sh
xcrun notarytool history --keychain-profile REL
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
