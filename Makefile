.PHONY: test docs

test: $(wildcard ./src/**/* ./build.zig ./build.zig.zon)
	zig build test

docs: $(wildcard ./src/**.*)
	mkdir -p ./zig-out
	zig build-lib -fno-emit-bin -femit-docs=./zig-out ./src/root.zig
