.PHONY: test smoke-test benchmark format format-check verify-api lint

test:
	nvim --headless --noplugin -l test/run.lua

smoke-test:
	nvim --noplugin -u test/manual_init.lua

# Real-system benchmark of the dispatch matrix. Spawns real subprocesses;
# not part of `make test`. Uses ~/Pictures/org-roam-logo.png by default,
# or test/fixtures/org-roam-logo.png as a fallback. Override with:
#   make benchmark FIXTURE=/path/to/image.png
benchmark:
	FIXTURE="$(FIXTURE)" nvim --headless --noplugin -l test/benchmark.lua

# Format Lua sources via stylua. Reads ./stylua.toml.
format:
	stylua lua test

# CI-friendly variant: exit non-zero if anything would change.
format-check:
	stylua --check lua test

# Verifies pinned upstream SHAs in docs/API.md still resolve in
# ~/projects/neovim (override path with NEOVIM_REPO env var).
verify-api:
	./scripts/verify_api.sh

# Asserts the four-entry public-surface rule on init.lua, iterm2.lua,
# sixel.lua. Fails if any M._<name> other than _supported is found.
lint:
	./scripts/lint_surface.sh
