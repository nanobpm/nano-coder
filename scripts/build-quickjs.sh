#!/bin/sh
# Build the vendored quickjs-ng engine into a static library (codemode spike).
# Incremental: rebuilds only when a vendored source is newer than the archive.
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)"
src="$dir/third_party/quickjs-ng"
out="$dir/.qjs-build"
lib="$out/libquickjs.a"
mkdir -p "$out"
shim="$dir/third_party/qjs_shim.c"
if [ -f "$lib" ] && [ -z "$(find "$src" "$shim" -newer "$lib" -type f | head -1)" ]; then exit 0; fi
CC="${CC:-cc}"
for f in quickjs libregexp libunicode dtoa; do
  "$CC" -O2 -fPIC -std=gnu11 -w -D_GNU_SOURCE -I"$src" -c "$src/$f.c" -o "$out/$f.o"
done
"$CC" -O2 -fPIC -std=gnu11 -Wall -I"$src" -c "$shim" -o "$out/qjs_shim.o"
rm -f "$lib"
ar rcs "$lib" "$out"/quickjs.o "$out"/libregexp.o "$out"/libunicode.o "$out"/dtoa.o "$out"/qjs_shim.o
