# Architecture Design: WillDeep Rename

## Rename Layers

| Layer | Change |
| --- | --- |
| Xcode product | `PRODUCT_NAME`, generated Info.plist keys, test host app path become `WillDeep`. |
| Bundle id | App and test bundle identifiers move to `com.willdeep.*`. |
| Help bundle | Help bundle name and plist metadata become `WillDeep.help` / `WillDeep Help`. |
| Runtime networking | `AgentNetworkSupport.userAgentHeaderValue` uses `WillDeep`; OpenRouter attribution uses `https://willdeep.com` and `WillDeep`. |
| Persistence | New support directory path uses `WillDeep`; UserDefaults and notification identifiers use `com.willdeep.*`. |
| CLI | `CommandLineToolInstaller` installs `willdeep`. |
| Docs | Public docs use `WillDeep` and `willdeep.com`. |

## Compatibility Notes

This release intentionally changes product identity. Existing local data under old app support paths may not auto-migrate in this patch. If migration becomes required, add a follow-up startup migrator that copies old `VeilWriter` support directories into `WillDeep` when the new directory is empty.
