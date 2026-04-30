.PHONY: test smoke-test

test:
	nvim --headless --noplugin -l test/run.lua

smoke-test:
	nvim --noplugin -u test/manual_init.lua
