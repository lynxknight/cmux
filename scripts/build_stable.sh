#!/usr/bin/env bash
set -euo pipefail

# Build the Release app and install to /Applications/cmux.app
exec "$(dirname "$0")/reloadp.sh" --install
