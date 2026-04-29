#!/usr/bin/env bash
# Run all dvw bats tests. Exports DVW_ROOT so tests can locate libs.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DVW_ROOT="$PWD"
exec bats tests/bats/*.bats
