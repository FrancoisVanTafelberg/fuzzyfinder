#!/usr/bin/env bash
# Build fff: one file, raylib and the font linked in. Put it on your PATH and
# run `fff` in the folder you want to search.
set -eu
cd "$(dirname "$0")"
mkdir -p build
odin build main_release -out:build/fff -o:speed -no-bounds-check "$@"
echo "ok - ./build/fff"
