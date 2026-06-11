# Requirement Specification Card

## Goal

将项目对外品牌从 `VeilWriter` 改为 `WillDeep`，并把 `willdeep.com` 作为新的官方域名标识。

## Core Requirements

- macOS app 展示名、产品名、帮助书名和构建产物应体现 `WillDeep`。
- 文档、README、产品概览、测试说明和帮助页面应使用 `WillDeep`。
- 命令行入口从 `veilwriter` 迁移到 `willdeep`，文档同步说明。
- 网络可观测信息应使用 `WillDeep`，版本号继续通过 `X-App-Version` 暴露。
- OpenRouter 署名 header 使用 `https://willdeep.com` 和 `WillDeep`。
- 版本更新到 `1.59.0-rc1`，并同步 CHANGELOG 与 product-overview。

## Boundaries

- 不处理 Apple Developer 门户、DNS 解析、官网部署、notary profile 凭据创建。
- 不强制重命名源码目录、Xcode scheme 和测试 target，除非其对用户可见或阻碍构建产物改名。

## Acceptance

- `rg "VeilWriter|veilwriter"` 只允许出现历史 changelog、兼容迁移说明或内部类型名等可解释残留。
- `rg "WillDeep|willdeep.com|willdeep"` 能覆盖 Bundle、文档、网络 header、CLI、持久化路径。
- 版本号统一为 `1.59.0-rc1`。
