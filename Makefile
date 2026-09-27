.PHONY: setup build run dev-open test test-runtime test-swift check check-ui-snapshots install-cli update-archive appcast beta publish-beta promote
.DEFAULT_GOAL := build

export MISTRALRS_METAL_PLATFORMS ?= macos

# One lock spans compilation, integration tests, and bundle staging.
ifneq ($(FRITZ_BUILD_CACHE_ACTIVE),$(CURDIR))
setup build run dev-open test test-runtime test-swift check check-ui-snapshots install-cli update-archive appcast beta publish-beta promote:
	+@python3 scripts/build-cache.py $(MAKE) --no-print-directory $@
else

setup:
	./scripts/setup-worktree.sh

build:
	./scripts/build-app.sh

run dev-open: build
	open -n "$$(cat dist/.last-built-app)"

test: test-runtime test-swift

test-runtime:
	cargo test --workspace --all-features --locked
	cargo build --locked
	python3 tests/integration.py
	python3 tests/coding_integration.py
	python3 tests/decision_integration.py
	python3 tests/test_release_tasks.py
	python3 tests/test_build_cache.py
	python3 tests/test_dev_runtime.py
	python3 tests/test_tool_evals.py

test-swift:
	swift test --scratch-path "$(FRITZ_SWIFT_BUILD)" --cache-path "$(FRITZ_SWIFT_CACHE)"
	swift test --package-path app --scratch-path "$(FRITZ_APP_SWIFT_BUILD)" --cache-path "$(FRITZ_SWIFT_CACHE)"

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

beta:
	@./scripts/beta-release.sh

publish-beta:
	@./scripts/publish-update.sh beta

promote:
	@./scripts/promote-release.sh

endif
