# Contributing to Fritz

Fritz is a native macOS app and a set of shared Swift/Rust libraries. Start with
[README.md](README.md), [the library guide](docs/libraries.md), and
[AGENTS.md](AGENTS.md) for architecture and local verification.

Open an issue to discuss substantial API changes. Keep pull requests focused,
document public API behavior, and preserve the existing app's storage and wire
formats. Run `make test` and `make check`; runtime and packaging changes also
need a complete staged app build and the affected workflow exercised with mock
providers. Never submit provider credentials, signing keys or personal chat data.

Project-authored code is licensed under **GNU AGPL version 3 only**
(`AGPL-3.0-only`), including the shared libraries. Contributions are accepted
under the same license. Contributors retain copyright; submitting a contribution
does not assign copyright or grant a proprietary relicensing exception.
Third-party material must retain its license and attribution. Please identify
any such material in your pull request.

Commercial use is permitted under the AGPL's terms. The license requires source
sharing in the circumstances it specifies; it is not a prohibition on commercial
forks. Any separate proprietary license requires rights from the relevant
copyright holders. No such exception or contributor agreement is established
by this repository.
