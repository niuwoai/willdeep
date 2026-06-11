# PRD: WillDeep Rename

## Background

用户已取得 `willdeep.com` 域名，项目需要从旧品牌迁移到 `WillDeep`。这次变更应让下载产物、运行时标识、帮助文档、README 和产品说明都统一到新品牌。

## Requirements

### Brand

- Primary product name: `WillDeep`
- Primary domain: `willdeep.com`
- Primary website URL: `https://willdeep.com`

### Runtime

- macOS app display name: `WillDeep`
- Built app product: `WillDeep.app`
- User-Agent: `WillDeep/{version} (macOS)`
- Version header: `X-App-Version: 1.59.0-rc1`
- MCP client info name: `WillDeep`

### CLI

- Primary CLI command: `willdeep`
- Install path: `~/.local/bin/willdeep`
- Documentation should stop presenting `veilwriter` as the primary command.

### Documentation

- README, product overview, TESTING, Help HTML, CHANGELOG all reflect `WillDeep`.
- Product overview documents the new domain and version.

## Non-goals

- DNS setup and website hosting.
- Apple notarization credential rotation.
- Remote GitHub rename.
