.PHONY: setup build run dev-open test check install-cli update-archive appcast
.DEFAULT_GOAL := build

setup:
	./scripts/setup-worktree.sh

build:
	./scripts/build-app.sh

run dev-open: build
	open -n "$$(cat dist/.last-built-app)"

test:
	cargo test --locked
	swift test --package-path app
	cargo build --locked
	python3 tests/integration.py
	python3 tests/coding_integration.py

check:
	cargo fmt --check
	cargo clippy --locked --all-targets -- -D warnings

install-cli:
	@CONFIGURATION=release $(MAKE) --no-print-directory build
	mkdir -p $(HOME)/.local/bin
	ln -sfn "$(CURDIR)/dist/Fritz.app/Contents/Resources/fritz" "$(HOME)/.local/bin/fritz"

update-archive:
	@CONFIGURATION=release $(MAKE) --no-print-directory build
	@./scripts/create-update-archive.sh

appcast:
	@./scripts/prepare-update.sh "$(CHANNEL)"
