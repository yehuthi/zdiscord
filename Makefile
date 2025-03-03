.PHONY: test doc clean

SRC=$(shell find ./src -type f -name '*.zig')

test: ${SRC} ./build.zig ./build.zig.zon
	zig test ./src/root.zig

doc: ${SRC}
	mkdir -p ./zig-out/doc
	zig build-lib -fno-emit-bin -femit-docs=./zig-out/doc ./src/root.zig

clean:
	rm -rf ./zig-out
