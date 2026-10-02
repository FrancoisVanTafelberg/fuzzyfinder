#!/usr/bin/env bash
# Build fff as a shared library. Safe to run while fff_dev is running: the
# host copies the library before loading it.
set -eu
cd "$(dirname "$0")"
mkdir -p build/hot_reload
ODIN_ROOT="$(odin root)"
odin build source -build-mode:dll -define:RAYLIB_SHARED=true \
    -extra-linker-flags:"-Wl,-rpath $ODIN_ROOT/vendor/raylib/linux" \
    -out:build/hot_reload/fff.so -debug "$@"
if ! pgrep -f build/fff_dev > /dev/null 2>&1; then
    odin build main_hot_reload -out:build/fff_dev -debug "$@"
fi
echo "ok - run ./build/fff_dev [folder]   (F5 reloads, F6 restarts)"
