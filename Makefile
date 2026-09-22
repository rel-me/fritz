.PHONY: setup build run dev-open test check install-cli
.DEFAULT_GOAL := build

setup:
	./scripts/setup-worktree.sh

build:
	./scripts/build-app.sh

run dev-open: build
	open dist/Fritz.app

test:
	cargo test --locked
	swift test --package-path app
	cargo build --locked
	python3 tests/integration.py

check:
	cargo fmt --check
	cargo clippy --locked --all-targets -- -D warnings

install-cli: build
	mkdir -p $(HOME)/.local/bin
	ln -sfn "$(CURDIR)/dist/Fritz.app/Contents/Resources/fritz" "$(HOME)/.local/bin/fritz"
