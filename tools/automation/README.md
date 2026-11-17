# Pécule Automation

This folder contains the native iOS automation workflow for Pécule.

## What it does

- boots a dedicated simulator
- launches the app in a deterministic in-memory mode
- runs UI smoke tests
- captures screenshots through XCTest attachments
- exports `.xcresult` bundles and screenshots into `artifacts/`

## Scripts

- `tools/automation/test.sh unit | ui-core | ui-full | only <Target/Class/method>`
  Single entry point for agents and humans. Refuses to start (exit 3) while an
  `xcodebuild` is running, writes the full log to `artifacts/test-results/<mode>.log`,
  prints the duration, the pass/fail/skip summary and only the failures, and
  returns the suite's exit code. Uses one DerivedData folder per checkout
  (override with `PECULE_DERIVED_DATA_ROOT`).

- `tools/automation/prepare_simulator.sh`
  Creates or boots the dedicated simulator `Pecule Automation iPhone 17`.
  Pass `--erase` to reset it before a run.

- `tools/automation/run_unit_tests.sh`
  Runs the `PeculeTests` unit test bundle (also used by the GitHub Actions
  workflow `.github/workflows/ci.yml`) and exports:
  - `artifacts/test-results/unit-tests.xcresult`

- `tools/automation/run_ui_smoke.sh`
  Runs the full UI suite: the whole `PeculeUITests` target except the screenshot
  suite `PeculeScreenshotUITests` (see `capture_screenshots.sh` below), serially,
  in about 25 minutes. The `smoke` name is historical: `PeculeSmokeUITests` is now
  only one of the classes it runs. It exports:
  - `artifacts/test-results/ui-smoke.xcresult`

- `tools/automation/capture_screenshots.sh`
  Runs the `PeculeScreenshotUITests` suite and exports:
  - `artifacts/test-results/ui-screenshots.xcresult`
  - `artifacts/screenshots/fr_FR/`

## Deterministic launch flags

The app reads these environment variables at launch:

- `PECULE_UI_TESTS_USE_IN_MEMORY_STORE=1`
- `PECULE_AUTOMATION_DATA_MODE=seeded|empty`
- `PECULE_AUTOMATION_DISABLE_ANIMATIONS=1`

UI tests also force:

- `-AppleLanguages (fr)`
- `-AppleLocale fr_FR`

## Typical usage

From the repository root:

```bash
tools/automation/prepare_simulator.sh --erase
tools/automation/run_ui_smoke.sh
tools/automation/capture_screenshots.sh
```

## Notes

- Screenshots are exported with stable human-readable names such as `dashboard_seeded.png`.
- The automation flow relies on `accessibilityIdentifier` values, not visible labels.
- The app uses an in-memory store for automation, so runs stay isolated and repeatable.
