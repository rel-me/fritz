.PHONY: setup build release-build run dev-open test test-runtime test-swift ci-prepare ci-prepare-runtime ci-prepare-swift check check-ui-snapshots install-cli update-archive appcast beta staging publish-beta publish-staging promote
.DEFAULT_GOAL := build

setup:
	./scripts/setup-worktree.sh

# One lock spans compilation, integration tests, and bundle staging.
ifneq ($(FRITZ_BUILD_CACHE_ACTIVE),$(CURDIR))
build release-build run dev-open test test-runtime test-swift ci-prepare ci-prepare-runtime ci-prepare-swift check check-ui-snapshots install-cli update-archive appcast beta staging publish-beta publish-staging promote:
	+@mise exec -- python3 scripts/build-cache.py $(MAKE) --no-print-directory $@
else

build:
	./scripts/build-app.sh

release-build:
	@CONFIGURATION=release $(MAKE) --no-print-directory build

run dev-open: build
	open -n "$$(cat dist/.last-built-app)"

test: test-runtime test-swift

# Compile before CI takes the account-wide Keychain/UI session lock.
# Keep the normal test commands afterward: Cargo rechecks freshness if another
# checkout used the shared target directory between preparation and execution.
ci-prepare: ci-prepare-runtime ci-prepare-swift

ci-prepare-runtime:
	cargo test --workspace --all-features --locked --no-run
	cargo build --locked
	$(MAKE) --no-print-directory check

ci-prepare-swift:
	swift build --build-tests --scratch-path "$(FRITZ_SWIFT_BUILD)" --cache-path "$(FRITZ_SWIFT_CACHE)"
	swift build --build-tests --package-path app --scratch-path "$(FRITZ_APP_SWIFT_BUILD)" --cache-path "$(FRITZ_SWIFT_CACHE)"

test-runtime:
	cargo test --workspace --all-features --locked
	cargo build --locked
	python3 tests/bundled_runtime.py
	python3 tests/test_release_tasks.py
	python3 tests/test_build_cache.py
	python3 tests/test_app_build_reuse.py
	python3 tests/test_parallel_build.py
	python3 tests/test_dev_runtime.py
	python3 tests/test_tool_evals.py
	python3 tests/test_local_decision_inference.py
	python3 tests/test_local_browser_pairing.py
	python3 tests/test_bosun_browser_pairing.py
	python3 tests/test_bosun_transport.py
	python3 tests/test_milestone_selection_eval.py

test-swift:
	swift test $(SWIFT_TEST_FLAGS) --scratch-path "$(FRITZ_SWIFT_BUILD)" --cache-path "$(FRITZ_SWIFT_CACHE)"
	swift test $(SWIFT_TEST_FLAGS) --package-path app --scratch-path "$(FRITZ_APP_SWIFT_BUILD)" --cache-path "$(FRITZ_SWIFT_CACHE)"

check-ui-snapshots:
	./scripts/check-ui-snapshots.sh

check:
	cargo fmt --all --check
	cargo clippy --workspace --all-features --locked --all-targets -- -D warnings

install-cli:
	@CONFIGURATION=release $(MAKE) --no-print-directory build
	mkdir -p $(HOME)/.local/bin
	ln -sfn "$(CURDIR)/dist/Fritz.app/Contents/Resources/fritz" "$(HOME)/.local/bin/fritz"

update-archive:
	@FRITZ_DISTRIBUTION=1 CONFIGURATION=release $(MAKE) --no-print-directory build
	@./scripts/create-update-archive.sh

appcast:
	@./scripts/prepare-update.sh "$(CHANNEL)"

beta staging:
	@./scripts/prerelease.sh "$@"

publish-beta publish-staging:
	@./scripts/publish-update.sh "$(patsubst publish-%,%,$@)"

promote:
	@./scripts/promote-release.sh

endif
