#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release
bin_dir="$(bash scripts/swift.sh build -c release --show-bin-path)"
app="${1:-$PWD/dist/Mischief Managed.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/FrameDesk" "$app/Contents/MacOS/FrameDesk"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
signing_identity="${FRAMEDESK_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" && -f Resources/LocalSigningIdentity.json ]]; then
    # Pin the approved public identity. Restricted Keychain queries can hide an
    # existing identity; never interpret that as permission to fall back to ad-hoc.
    signing_identity="$(python3 -c 'import json,re; d=json.load(open("Resources/LocalSigningIdentity.json")); v=d["sha1"]; assert re.fullmatch(r"[0-9A-Fa-f]{40}",v), "Invalid signing fingerprint"; print(v)')"
fi

codesign --force --sign "${signing_identity:--}" --identifier com.pkhodo.FrameDesk "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
