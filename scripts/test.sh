#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed, SwiftPM doesn't always find
# the Swift Testing macro plugin, so point it there explicitly when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN_DIR="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [[ -d "$PLUGIN_DIR" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR" "$@"
else
  swift test "$@"
fi
