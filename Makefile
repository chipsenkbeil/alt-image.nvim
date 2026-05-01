.PHONY: test smoke-test benchmark format format-check

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
