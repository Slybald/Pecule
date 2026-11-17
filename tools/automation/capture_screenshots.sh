#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools/automation"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
RESULTS_DIR="$ARTIFACTS_DIR/test-results"
SCREENSHOTS_DIR="$ARTIFACTS_DIR/screenshots/fr_FR"
RESULT_BUNDLE_PATH="$RESULTS_DIR/ui-screenshots.xcresult"
TMP_ROOT="${TMPDIR:-/tmp}/PeculeAutomation"
DERIVED_DATA_DIR="$TMP_ROOT/DerivedData/ui-screenshots"
TEMP_RESULT_BUNDLE_PATH="$TMP_ROOT/test-results/ui-screenshots.xcresult"

mkdir -p "$RESULTS_DIR" "$ARTIFACTS_DIR/DerivedData"
rm -rf "$RESULT_BUNDLE_PATH" "$DERIVED_DATA_DIR" "$SCREENSHOTS_DIR" "$TEMP_RESULT_BUNDLE_PATH"

DEVICE_ID="$("$TOOLS_DIR/prepare_simulator.sh" --erase | tail -n 1)"

cd "$ROOT_DIR"
xcodegen generate
# Un échec de xcodebuild ne doit pas empêcher l'export du paquet de résultats : c'est alors qu'on en a
# besoin pour comprendre l'échec. Le code de sortie de xcodebuild est conservé.
# `status` est réservé en zsh (alias de `$?`, en lecture seule) : d'où `test_status`.
test_status=0
xcodebuild test \
    -project "Pecule.xcodeproj" \
    -scheme "Pecule" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -only-testing:PeculeUITests/PeculeScreenshotUITests \
    -resultBundlePath "$TEMP_RESULT_BUNDLE_PATH" \
    -derivedDataPath "$DERIVED_DATA_DIR" || test_status=$?

rsync -a "$TEMP_RESULT_BUNDLE_PATH" "$RESULTS_DIR/" || true

# Des captures d'une passe en échec seraient incomplètes ou trompeuses : pas d'export des pièces
# jointes, seul le paquet de résultats est conservé.
if [[ $test_status -ne 0 ]]; then
    if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
        echo "Screenshot tests failed (exit $test_status); attachments not exported. Result bundle: $RESULT_BUNDLE_PATH" >&2
    else
        echo "Screenshot tests failed (exit $test_status); no result bundle was produced at $TEMP_RESULT_BUNDLE_PATH" >&2
    fi
    exit $test_status
fi

xcrun xcresulttool export attachments \
    --path "$TEMP_RESULT_BUNDLE_PATH" \
    --output-path "$SCREENSHOTS_DIR"

python3 - <<'PY' "$SCREENSHOTS_DIR/manifest.json" "$SCREENSHOTS_DIR"
import json
import pathlib
import shutil
import sys

manifest_path = pathlib.Path(sys.argv[1])
screenshots_dir = pathlib.Path(sys.argv[2])

if manifest_path.exists():
    manifest = json.loads(manifest_path.read_text())
    for test_entry in manifest:
        for attachment in test_entry.get("attachments", []):
            exported_name = attachment.get("exportedFileName")
            suggested_name = attachment.get("suggestedHumanReadableName")
            if not exported_name or not suggested_name:
                continue

            source = screenshots_dir / exported_name
            if not source.exists():
                continue

            cleaned_name = suggested_name.split("_0_", 1)[0] + source.suffix
            destination = screenshots_dir / cleaned_name

            if destination.exists():
                destination.unlink()

            shutil.move(str(source), str(destination))
PY

echo "Screenshots exported to: $SCREENSHOTS_DIR"
