#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools/automation"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
RESULTS_DIR="$ARTIFACTS_DIR/test-results"
RESULT_BUNDLE_PATH="$RESULTS_DIR/unit-tests.xcresult"
TMP_ROOT="${TMPDIR:-/tmp}/PeculeAutomation"
# test.sh fournit un DerivedData par checkout (PECULE_DERIVED_DATA_ROOT) ; sans lui (CI, appel direct), dossier commun.
DERIVED_DATA_DIR="${PECULE_DERIVED_DATA_ROOT:-$TMP_ROOT/DerivedData}/unit-tests"
TEMP_RESULT_BUNDLE_PATH="$TMP_ROOT/test-results/unit-tests.xcresult"

mkdir -p "$RESULTS_DIR"
rm -rf "$RESULT_BUNDLE_PATH" "$DERIVED_DATA_DIR" "$TEMP_RESULT_BUNDLE_PATH"

DEVICE_ID="$("$TOOLS_DIR/prepare_simulator.sh" | tail -n 1)"

cd "$ROOT_DIR"
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
fi

# Simulator builds are ad-hoc signed, which the Keychain-backed tests require; never disable signing here.
# Un échec de xcodebuild ne doit pas empêcher l'export du paquet de résultats : c'est alors qu'on en a
# besoin (le job CI l'envoie sur échec). Le code de sortie de xcodebuild est conservé, et rendu à la fin.
# `status` est réservé en zsh (alias de `$?`, en lecture seule) : d'où `test_status`.
test_status=0
xcodebuild test \
    -project "Pecule.xcodeproj" \
    -scheme "Pecule" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -only-testing:PeculeTests \
    -resultBundlePath "$TEMP_RESULT_BUNDLE_PATH" \
    -derivedDataPath "$DERIVED_DATA_DIR" || test_status=$?

rsync -a "$TEMP_RESULT_BUNDLE_PATH" "$RESULTS_DIR/" || true

if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
    echo "Unit tests result bundle: $RESULT_BUNDLE_PATH"
else
    echo "No result bundle was produced at $TEMP_RESULT_BUNDLE_PATH" >&2
fi
exit $test_status
