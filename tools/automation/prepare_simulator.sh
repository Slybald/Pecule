#!/bin/zsh

set -euo pipefail

DEVICE_NAME="${PECULE_AUTOMATION_DEVICE_NAME:-Pecule Automation iPhone 17}"
DEVICE_TYPE="${PECULE_AUTOMATION_DEVICE_TYPE:-iPhone 17}"
ERASE_DEVICE=0

if [[ "${1-}" == "--erase" ]]; then
    ERASE_DEVICE=1
fi

existing_device_line="$(
    xcrun simctl list devices available |
        grep -F "$DEVICE_NAME" |
        head -n 1 || true
)"

device_id="$(
    printf '%s\n' "$existing_device_line" |
        sed -E 's/.*\(([A-F0-9-]+)\) \((Booted|Shutdown)\).*/\1/'
)"

if [[ -z "$device_id" ]]; then
    device_id="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE")"
fi

if [[ "$ERASE_DEVICE" -eq 1 ]]; then
    xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
    xcrun simctl erase "$device_id"
fi

xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_id" -b

echo "$device_id"
