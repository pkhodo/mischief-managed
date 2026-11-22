#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift_binary="$(xcrun --find swift)"
testing_plugin="$(dirname "$swift_binary")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
test_flags=(--disable-xctest)
if [[ -f "$testing_plugin" ]]; then
    test_flags+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
# Newer command-line toolchains ship Testing.framework under Library/Developer,
# while the legacy native engine searches a different default framework path.
frameworks="$(dirname "$swift_binary")/../../Library/Developer/Frameworks"
if [[ "${FRAMEDESK_BUILD_SYSTEM:-}" == "native" && -d "$frameworks/Testing.framework" ]]; then
    test_flags+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi
bash scripts/swift.sh test "${test_flags[@]}"
bash scripts/build.sh
if [[ "${1:-}" == "--integration" ]]; then
    python3 scripts/integration.py "${2:-$PWD/dist/Mischief Managed.app}" "${3:-$PWD/.build/integration}"
fi
