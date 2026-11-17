#!/bin/zsh

# Noyau UI : les parcours qui doivent casser en premier si une régression arrive.
# Durée variable selon les parcours de planification ajoutés ; exécuter en série.
# La suite complète (toute la cible PeculeUITests, hors captures) est run_ui_smoke.sh, à lancer au
# moment de fusionner.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools/automation"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
RESULTS_DIR="$ARTIFACTS_DIR/test-results"
RESULT_BUNDLE_PATH="$RESULTS_DIR/ui-core.xcresult"
TMP_ROOT="${TMPDIR:-/tmp}/PeculeAutomation"
# test.sh fournit un DerivedData par checkout (PECULE_DERIVED_DATA_ROOT) ; sans lui (CI, appel direct), dossier commun.
DERIVED_DATA_DIR="${PECULE_DERIVED_DATA_ROOT:-$TMP_ROOT/DerivedData}/ui-core"
TEMP_RESULT_BUNDLE_PATH="$TMP_ROOT/test-results/ui-core.xcresult"

# Un parcours par responsabilité de destination, plus les deux invariants financiers visibles.
# S'y ajoutent l'ordre des onglets, dont dépend l'adressage de tous les autres tests, et la
# connexion bancaire de bout en bout, qui est le premier écran d'une installation neuve.
# Le plafond mensuel partagé et la courbe bancaire font désormais partie de ce noyau.
CORE_TESTS=(
    "PeculeUITests/GoalAllocationUITests"
    "PeculeUITests/PurchaseSimulationUITests"
    "PeculeUITests/TreasuryCalendarUITests"
    "PeculeUITests/ProvisionUITests/testCreateReserveEditCancelAndOpenFromBudget"
    "PeculeUITests/ProvisionUITests/testMatchAndUndoPaymentFromAProvision"
    "PeculeUITests/CommitmentUITests/testMatchingAndRemovingABankPaymentUpdatesTheRemainingAmount"
    "PeculeUITests/CommitmentUITests/testCreateEditStopAndCancelCommitmentFromBudget"
    "PeculeUITests/CommitmentUITests/testDatedFiniteCommitmentAppearsOnHomeAndStopsThere"
    "PeculeUITests/RootTabOrderUITests/testEachPositionCarriesItsExpectedTabAndOpensItsOwnScreen"
    "PeculeUITests/BankConnectionUITests/testConnectingABankFromTheEmptyAccountsTabImportsAndShowsABalance"
    "PeculeUITests/ProductEvolutionUITests/testFiveDestinationsAndSecondaryHabits"
    "PeculeUITests/ProductEvolutionUITests/testBankHomeHasTrajectoryAndBudgetExplanation"
    "PeculeUITests/ProductEvolutionUITests/testMonthlyBudgetIsSharedBetweenHomeAndBudgetAndCanBeRemoved"
    "PeculeUITests/ProductEvolutionUITests/testAccountHistoryAndGlobalOperationsHaveSeparateDestinations"
    "PeculeUITests/ProductEvolutionUITests/testGoalReservationAppearsInAllowanceExplanation"
    "PeculeUITests/PeculeSmokeUITests/testBudgetsScreenSetsAMonthlyBudgetFromSettings"
    "PeculeUITests/PeculeSmokeUITests/testOperationsSearchFindsBankMovementAndFiltersCanBeCleared"
    "PeculeUITests/PeculeSmokeUITests/testUnlinkingBankWhileLinkPickerIsOpenDoesNotKeepDeletedTransaction"
    "PeculeUITests/PeculeSmokeUITests/testSwipeDeletingAGoalAsksForConfirmationAndCanBeCancelled"
    "PeculeUITests/BankConnectionUITests/testGatewaySettingsStayHiddenUntilDeveloperModeIsEnabled"
    "PeculeUITests/BankConnectionUITests/testTheGatewayFormRefusesAnInvalidAddressAndAnEmptyToken"
)

mkdir -p "$RESULTS_DIR" "$ARTIFACTS_DIR/DerivedData"
rm -rf "$RESULT_BUNDLE_PATH" "$DERIVED_DATA_DIR" "$TEMP_RESULT_BUNDLE_PATH"

DEVICE_ID="$("$TOOLS_DIR/prepare_simulator.sh" | tail -n 1)"

ONLY_TESTING=()
for test in "${CORE_TESTS[@]}"; do
    ONLY_TESTING+=("-only-testing:$test")
done

cd "$ROOT_DIR"
xcodegen generate
# En série : mesuré plus rapide et plus fiable que des clones parallèles sur cette machine.
# Un échec de xcodebuild ne doit pas empêcher l'export du paquet de résultats : c'est alors qu'on en a
# besoin (le job CI l'envoie sur échec). Le code de sortie de xcodebuild est conservé, et rendu à la fin.
# `status` est réservé en zsh (alias de `$?`, en lecture seule) : d'où `test_status`.
test_status=0
xcodebuild test \
    -project "Pecule.xcodeproj" \
    -scheme "Pecule" \
    -destination "platform=iOS Simulator,id=$DEVICE_ID" \
    "${ONLY_TESTING[@]}" \
    -resultBundlePath "$TEMP_RESULT_BUNDLE_PATH" \
    -derivedDataPath "$DERIVED_DATA_DIR" || test_status=$?

rsync -a "$TEMP_RESULT_BUNDLE_PATH" "$RESULTS_DIR/" || true

if [[ -e "$RESULT_BUNDLE_PATH" ]]; then
    echo "UI core result bundle: $RESULT_BUNDLE_PATH"
else
    echo "No result bundle was produced at $TEMP_RESULT_BUNDLE_PATH" >&2
fi
exit $test_status
