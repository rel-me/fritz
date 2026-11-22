# Fritz for iPhone builds and TestFlight

The shared Xcode project contains the `Fritz-iOS` scheme for iPhone on iOS
18 or later. Xcode builds the Rust runtime for the selected iOS SDK and links it
into the app. The runtime shares provider discovery, request encoding, and
stream decoding with Fritz for Mac and uses Apple's TLS implementation on iOS.

## Build and verify

On an Apple Silicon Mac, use the Fritz toolchain from `mise.toml`, Xcode with
the iOS SDK, and an installed iPhone simulator runtime. Add the Rust targets
to the pinned toolchain:

```sh
mise install
rustup target add --toolchain "$(mise current rust)" aarch64-apple-ios aarch64-apple-ios-sim
make ios-build
make ios-test
```

Use the **Fritz-iOS** scheme in `app/Fritz.xcodeproj` to run the app in a
simulator. If target structure changes, regenerate with
`mise exec -- xcodegen generate --spec app/project.yml`. The UI test creates
its own simulator using the iPhone 17 Pro device type and runs Fritz's
keyless mock provider on port 18743. It covers provider setup and discovery,
chat streaming, an access error, stopping a reply, and relaunch restoration.
Only simulator builds accept keyless HTTP to the mock at `127.0.0.1`.

## Upload an internal beta

Sign in to the Fritz Apple Developer team in **Xcode → Settings → Accounts**.
The team needs an explicit `dev.fritz.app` App ID and an iOS app record in
App Store Connect. If the team already has a Fritz record with that ID, add
the iOS platform there. Alternatively, for automated signing and upload, set
`FRITZ_IOS_API_KEY_PATH`, `FRITZ_IOS_API_KEY_ID`, and
`FRITZ_IOS_API_ISSUER_ID` for an authorized App Store Connect team key.
Keep the private key outside the checkout.

```sh
export FRITZ_IOS_TEAM=U2622K69A6
export FRITZ_IOS_BUILD_NUMBER=1  # Use the next unused build number.
make ios-archive
make ios-upload
```

`make ios-archive` creates a signed device archive at
`dist/ios/Fritz.xcarchive`. `make ios-upload` uploads that archive as a
TestFlight Internal Only build. An upload can be retried with the same archive
if Apple has not accepted its build number.

Wait for processing in **App Store Connect → Fritz → TestFlight**. Assign the
build to the intended internal tester group if it is not automatically
distributed. Verify it appears in TestFlight for an eligible tester, then
install it on an iPhone and send a message, stop a response, and relaunch to
confirm the transcript and draft are restored.

Use the [iPhone privacy policy](../ios-privacy.md) for distribution metadata.
Apple documents [app record setup](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/),
[build uploads](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
and [internal TestFlight groups](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).
