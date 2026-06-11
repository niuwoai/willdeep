# Test Plan

## Checks

- Run `rg "1.58.0-rc18|1.58.0-rc17"` to ensure old versions are gone outside historical changelog entries.
- Run `rg "VeilWriter|veilwriter"` and review allowed residuals.
- Run `rg "WillDeep|willdeep|willdeep.com"` and confirm expected coverage.
- Run Xcode build or focused tests when available:
  - `xcodebuild test -project Xedit.xcodeproj -scheme Xedit -destination 'platform=macOS' -only-testing:XeditTests`

## Acceptance Evidence

Results will be recorded in `acceptance.md`.
