#!/bin/bash
# Smoke test (principle 8): unit tests, a release build, then the main path end to end against a
# temporary store and a private pasteboard. Never touches your real clipboard or history.
set -euo pipefail
cd "$(dirname "$0")"

swift test
./build.sh
build/devPaste.app/Contents/MacOS/devPaste --smoke
