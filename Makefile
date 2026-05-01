.PHONY: test smoke-test format format-check

test:
	nvim --headless --noplugin -l test/run.lua

smoke-test:
	nvim --noplugin -u test/manual_init.lua

# Format Lua sources via stylua. Reads ./stylua.toml.
format:
	stylua lua test

# CI-friendly variant: exit non-zero if anything would change.
format-check:
	stylua --check lua test
