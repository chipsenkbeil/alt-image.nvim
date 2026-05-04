.PHONY: smoke-test smoke-placeholder test test-unit test-e2e format format-check verify-api lint

smoke-test:
	nvim --noplugin -u test/manual_init.lua

smoke-placeholder:
	nvim --noplugin -u test/manual_init.lua -c "AltImgTest placeholder editor"

# Run the full test suite. FILTER='lua-pattern' optional.
test:
	nvim --headless -l test/runner.lua $(FILTER)

# Unit tests only (in-process, fast).
test-unit:
	nvim --headless -l test/runner.lua --unit $(FILTER)

# Harness/end-to-end tests only (spawn child nvim per test).
test-e2e:
	nvim --headless -l test/runner.lua --e2e $(FILTER)

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
