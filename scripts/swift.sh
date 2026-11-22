#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
subcommand="$1"
shift
if [[ -n "${FRAMEDESK_BUILD_SYSTEM:-}" ]]; then
    set -- --build-system "$FRAMEDESK_BUILD_SYSTEM" "$@"
fi
exec swift "$subcommand" --cache-path .build/swift-cache --config-path .build/swift-config --security-path .build/swift-security --disable-sandbox "$@"
