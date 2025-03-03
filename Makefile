.PHONY: test docs

SRC=$(shell find ./src -type f -name '*.zig')

test: ${SRC} ./build.zig ./build.zig.zon
	zig test ./src/root.zig

docs: ${SRC}
	mkdir -p ./zig-out
	zig build-lib -fno-emit-bin -femit-docs=./zig-out ./src/root.zig
