#!/bin/zsh

# Suite UI complète : toute la cible PeculeUITests, sauf les captures d'écran (PeculeScreenshotUITests,
# lancées à part par capture_screenshots.sh). Le nom « smoke » est historique : la classe
# PeculeSmokeUITests n'en est plus qu'une partie. En série, environ 25 minutes. Le noyau rapide, à
# lancer à chaque changement, est run_ui_core.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools/automation"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
RESULTS_DIR="$ARTIFACTS_DIR/test-results"
RESULT_BUNDLE_PATH="$RESULTS_DIR/ui-smoke.xcresult"
TMP_ROOT="${TMPDIR:-/tmp}/PeculeAutomation"
# test.sh fournit un DerivedData par checkout (PECULE_DERIVED_DATA_ROOT) ; sans lui (CI, appel direct), dossier commun.
DERIVED_DATA_DIR="${PECULE_DERIVED_DATA_ROOT:-$TMP_ROOT/DerivedData}/ui-smoke"
TEMP_RESULT_BUNDLE_PATH="$TMP_ROOT/test-results/ui-smoke.xcresult"

mkdir -p "$RESULTS_DIR" "$ARTIFACTS_DIR/DerivedData"
rm -rf "$RESULT_BUNDLE_PATH" "$DERIVED_DATA_DIR" "$TEMP_RESULT_BUNDLE_PATH"

DEVICE_ID="$("$TOOLS_DIR/prepare_simulator.sh" | tail -n 1)"

cd "$ROOT_DIR"
xcodegen generate
# Un échec de xcodebuild ne doit pas empêcher l'export du paquet de résultats : c'est alors qu'on en a
# besoin (le job CI l'envoie sur échec). Le code de sortie de xcodebuild est conservé, et rendu à la fin.
# `status` est réservé en zsh (alias de `$?`, en lecture seule) : d'où `test_status`.
test_status=0
xcodebuild test \
    -project "Pecule.xcodeproj" \
    -scheme "Pecule" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    -only-testing:PeculeUITests \
    -skip-testing:PeculeUITests/PeculeScreenshotUITests \
    -resultBundlePath "$TEMP_RESULT_BUNDLE_PATH" \
    -derivedDataPath "$DERIVED_DATA_DIR" || test_status=$?

rsync -a "$TEMP_RESULT_BUNDLE_PATH" "$RESULTS_DIR/" || true

if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
    echo "UI smoke tests result bundle: $RESULT_BUNDLE_PATH"
else
    echo "No result bundle was produced at $TEMP_RESULT_BUNDLE_PATH" >&2
fi
exit $test_status
