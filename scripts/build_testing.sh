#!/usr/bin/env bash
set -euo pipefail

# Build-only wrapper around reload.sh with a fixed "dev" tag.
# Does not launch the app — use reload.sh --tag dev to build + launch.
exec "$(dirname "$0")/reload.sh" --tag dev "$@"
