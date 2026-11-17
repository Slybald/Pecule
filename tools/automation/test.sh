#!/bin/zsh

# Point d'entrée unique des suites de tests, pour Nicolas comme pour les agents :
#
#   tools/automation/test.sh unit        # PeculeTests, via run_unit_tests.sh
#   tools/automation/test.sh ui-core     # noyau UI, via run_ui_core.sh, à chaque changement d'interface
#   tools/automation/test.sh ui-full     # toute la cible UI hors captures, via run_ui_smoke.sh (~25 min)
#   tools/automation/test.sh only <Cible[/Classe[/méthode]]>
#                                        # ex. PeculeTests/FormattersTests/testAmountPlaceholderFollowsTheAppLocale
#
# Refuse de démarrer (code 3) si un xcodebuild tourne déjà : deux suites simultanées sur le simulateur
# partagé se tuent mutuellement. Attendre sa fin par une boucle sur `pgrep -x xcodebuild`, sans la tuer.
# Le journal complet va dans artifacts/test-results/<mode>.log ; l'écran ne montre que la durée, le
# résumé (passés, échoués, ignorés) et les seuls échecs. Code de sortie : celui de la suite, sauf 4 quand
# elle se dit verte sans avoir exécuté un seul test (identifiant `only` mal écrit) et 2 pour un usage
# incorrect.
# DerivedData : un dossier par checkout, $TMPDIR/PeculeAutomation/<checkout>/DerivedData/<mode>, pour que
# deux dossiers de travail ne compilent jamais dans le même ; PECULE_DERIVED_DATA_ROOT le remplace.
# `only` garde son DerivedData d'une fois sur l'autre (relance rapide) ; les autres modes repartent de
# zéro, comme les scripts run_* qu'ils appellent.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools/automation"
RESULTS_DIR="$ROOT_DIR/artifacts/test-results"

usage() {
    cat >&2 <<'EOF'
Usage : tools/automation/test.sh unit | ui-core | ui-full | only <Cible[/Classe[/méthode]]>
  unit     PeculeTests (run_unit_tests.sh)
  ui-core  noyau UI (run_ui_core.sh), à chaque changement d'interface
  ui-full  toute la cible UI hors captures (run_ui_smoke.sh), environ 25 min
  only     une cible, une classe ou un test, ex. PeculeTests/FormattersTests/testAmountPlaceholderFollowsTheAppLocale
EOF
    exit 2
}

mode="${1-}"
case "$mode" in
    unit)    [[ $# -eq 1 ]] || usage; script="run_unit_tests.sh"; bundle_name="unit-tests.xcresult" ;;
    ui-core) [[ $# -eq 1 ]] || usage; script="run_ui_core.sh"; bundle_name="ui-core.xcresult" ;;
    ui-full) [[ $# -eq 1 ]] || usage; script="run_ui_smoke.sh"; bundle_name="ui-smoke.xcresult" ;;
    only)    [[ $# -eq 2 && -n "$2" ]] || usage; test_id="$2"; bundle_name="only.xcresult" ;;
    *)       usage ;;
esac

if running_pids="$(pgrep -x xcodebuild)"; then
    echo "test.sh : un xcodebuild tourne déjà (pid ${running_pids//$'\n'/, }) ; deux suites simultanées se tuent mutuellement." >&2
    echo "Attendre sa fin par une boucle sur « pgrep -x xcodebuild », puis relancer. Ne pas le tuer." >&2
    exit 3
fi

checkout_id="${ROOT_DIR:t}-$(md5 -qs "$ROOT_DIR" | cut -c1-8)"
export PECULE_DERIVED_DATA_ROOT="${PECULE_DERIVED_DATA_ROOT:-${${TMPDIR:-/tmp}%/}/PeculeAutomation/$checkout_id/DerivedData}"

mkdir -p "$RESULTS_DIR"
log_path="$RESULTS_DIR/$mode.log"
bundle_path="$RESULTS_DIR/$bundle_name"

# Les erreurs sont propagées à la main : appelée à gauche d'un `||`, la fonction ne bénéficie pas de `set -e`.
run_only() {
    local device_id
    rm -rf "$bundle_path"
    device_id="$("$TOOLS_DIR/prepare_simulator.sh" | tail -n 1)" || return $?
    cd "$ROOT_DIR" || return $?
    if command -v xcodegen >/dev/null 2>&1; then
        xcodegen generate || return $?
    fi
    xcodebuild test \
        -project "Pecule.xcodeproj" \
        -scheme "Pecule" \
        -destination "platform=iOS Simulator,id=$device_id" \
        "-only-testing:$test_id" \
        -resultBundlePath "$bundle_path" \
        -derivedDataPath "$PECULE_DERIVED_DATA_ROOT/only"
}

# Arrête d'abord nos propres descendants (xcodebuild compris) : un orphelin ferait refuser les passes suivantes.
kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null; }
trap 'for c in $(pgrep -P $$); do kill_tree "$c"; done; echo "test.sh : interrompu. Des processus CoreSimulator orphelins ralentiront les passes suivantes : pkill -x xcodebuild ; xcrun simctl shutdown all ; pkill -f CoreSimulatorService" >&2; exit 130' INT TERM

echo "test.sh $mode : démarrage à $(date '+%H:%M:%S'), journal complet dans ${log_path#$ROOT_DIR/}"
start_seconds=$SECONDS
test_status=0
if [[ "$mode" == "only" ]]; then
    run_only >"$log_path" 2>&1 || test_status=$?
else
    "$TOOLS_DIR/$script" >"$log_path" 2>&1 || test_status=$?
fi
elapsed=$(( SECONDS - start_seconds ))
printf 'Durée : %d min %02d s, code de sortie %d\n' $(( elapsed / 60 )) $(( elapsed % 60 )) "$test_status"

# Résumé du paquet de résultats : compteurs, puis un seul message par test en échec.
SUMMARY_PY='
import json, sys
data = json.load(sys.stdin)
total = data.get("totalTestCount", 0)
line = "Résumé : {} : {} passés, {} échoués, {} ignorés".format(
    data.get("result", "?"), data.get("passedTests", 0), data.get("failedTests", 0), data.get("skippedTests", 0))
if data.get("expectedFailures"):
    line += ", {} échecs attendus".format(data["expectedFailures"])
print(line + " (total {})".format(total))
failures = {}
for failure in data.get("testFailures") or []:
    name = failure.get("testIdentifierString") or "{}/{}".format(failure.get("targetName", "?"), failure.get("testName", "?"))
    failures.setdefault(name, []).append(" ".join((failure.get("failureText") or "").split()))
if failures:
    print("Échecs :")
for name, texts in failures.items():
    more = " (+{} autres messages)".format(len(texts) - 1) if len(texts) > 1 else ""
    print("  ✗ {} : {}{}".format(name, texts[0][:300], more))
sys.exit(10 if total == 0 else 0)
'

summary_json=""
if [[ -d "$bundle_path" ]]; then
    summary_json="$(xcrun xcresulttool get test-results summary --path "$bundle_path" --compact 2>/dev/null)" || summary_json=""
fi
summary_status=0
if [[ -n "$summary_json" ]]; then
    echo "Paquet : ${bundle_path#$ROOT_DIR/}"
    printf '%s' "$summary_json" | python3 -I -c "$SUMMARY_PY" || summary_status=$?
else
    echo "Aucun résumé : pas de paquet de résultats lisible à ${bundle_path#$ROOT_DIR/}. Erreurs du journal :"
    grep -E 'error:|\*\* [A-Z -]*FAILED \*\*|Testing failed' "$log_path" | tail -n 20 || tail -n 15 "$log_path"
fi

if [[ $test_status -eq 0 && $summary_status -eq 10 ]]; then
    echo "test.sh : aucun test exécuté. Vérifier l'identifiant (Cible/Classe/méthode) ou la sélection." >&2
    exit 4
fi
exit $test_status
