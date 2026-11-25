# 第三方参考说明

本仓库不捆绑第三方 SDK、预编译库、上游应用源码或下载的研究仓库。界面图标由 `scripts/generate_icon.py` 程序化生成。

实现过程中查阅了公共协议/接口资料及独立互操作性实现，包括：

- [Kumone](https://github.com/missuo/kumone)（参考快照 `a8db2a42a4b2683b63c13921b1f42cc8d8d1d992`；其参考目录登记为 `LGPL-3.0-only`）。本仓库仅记录为接口调查参考；不含其 SDK 或可识别的大段实现复制。网易云协议常量及标准 AES/RSA 操作本身不是对该仓库的许可声明。
- [NeteaseCloudMusicApiEnhanced/api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)，快照 `23d9e9d7ee5dfeccfc3b15916ccd9da1f76d3ea4`：`NeteaseXEAPI.swift` 的 XEAPI 互操作实现改编自 `util/crypto.js` 与 `module/register_xeapikey.js`；上游采用 MIT（Copyright (c) 2013-2022 Binaryify），完整许可保留在该 Swift 文件头。标准 AES、X25519、HKDF、HMAC 与 gzip 使用 Apple 系统框架/系统库；独立 Node/Swift 向量为合成测试，不使用真实账号。该模块的上游许可不构成本项目整体的许可授予。
- [LX Music](https://github.com/lyswhut/lx-music-desktop) 及网易云互操作文档：只作行为与端点研究；不随项目分发上游源码、运行时包或 JS 插件。
- [OpenSubsonic 文档](https://opensubsonic.netlify.app/docs/)：用于核对服务器 API 契约，不是代码依赖。
- [Apple 平台 API 文档](https://developer.apple.com/documentation/)：用于 Swift/iOS 公共 API。

源码只读 spot check 覆盖 `NeteaseCrypto.swift`、`CatalogClient.swift` 和 `SourceBootstrap.js`，对照本地研究快照未发现可识别的大段逐字复制；通用系统 API 调用与公开协议常量可能相同。该有限检查不是法律意见，也不替代所有历史/来源的正式代码审计。

音乐平台、服务器、协议名称和商标仍归其各自权利人。本项目不隶属于网易、酷狗、Apple 或 OpenSubsonic。联网服务可能要求你自行拥有账户并遵守各服务的条款；本软件不提供绕过访问控制、风控或版权限制的保证。

**本项目没有附加开源许可证；不要把公开可见或 GitHub 可 fork 误认为获得了通用再许可。** 第三方项目仍受其自身许可约束。
