# Acceptance

## Result

WillDeep brand migration is implemented for the current repository state.

## Evidence

| Requirement | Evidence | Status |
| --- | --- | --- |
| Product name and public docs use WillDeep | README, TESTING, product-overview, Help HTML, Xcode project, Info.plist updated. | Passed |
| Domain uses willdeep.com | README, product-overview, CHANGELOG, OpenRouter `HTTP-Referer` and provider notice use `https://willdeep.com`. | Passed |
| Version is `1.59.0-rc1` | `MARKETING_VERSION` appears in 6 Xcode build settings; Help Info.plist and product-overview match. | Passed |
| Runtime version observability remains | `AgentNetworkSupport.applyStandardHeaders` still sets `X-App-Version`; User-Agent is now `WillDeep/{version} (macOS)`. | Passed |
| CLI primary command is `willdeep` | `CommandLineToolInstaller.toolName`, install path, README, TESTING, Localizable strings updated. | Passed |
| Old public brand is absent from current files | `rg "VeilWriter|veilwriter|83d.me|im.some.veilwriter|im.some.willdeep|1.58.0-rc18|1.58.0-rc17|1.52.1--rc43|1.43.x" Xedit XeditTests XeditUITests Xedit.xcodeproj Help/WillDeep.help scripts README.md TESTING.md product-overview.md -g '!*.xcuserstate'` returned no matches. | Passed |
| Plists are valid | `plutil -lint Xedit/Info.plist Help/WillDeep.help/Contents/Info.plist` passed. | Passed |
| App builds | `xcodebuild build -project Xedit.xcodeproj -scheme Xedit -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO` passed and produced `WillDeep.app`. | Passed |
| Unit tests | `xcodebuild test ... CODE_SIGNING_ALLOWED=NO -only-testing:XeditTests` compiled the app/tests but test launch failed because sandbox blocked `com.apple.testmanagerd.control`. | Environment Blocked |

## Notes

- The first `xcodebuild test` attempt without signing override failed due missing local `Mac Development` private key for Team `ZH2S7D6PL6`.
- With signing disabled, compilation proceeded and stale `VeilWriter` build artifacts were removed by Xcode, but test execution could not communicate with the test runner under the current sandbox.
