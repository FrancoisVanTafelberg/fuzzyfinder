#!/usr/bin/env bash
# The headless tests: the matcher and the ignore rules.
set -eu
cd "$(dirname "$0")"
odin test source/fuzzy
odin test source/ignore
