# 听流 TingFlow — 公开构建快照

iOS 16+ 原生 SwiftUI 音乐播放器，iOS 26 使用系统 TabView、搜索 Tab、底部播放器附件与滚动收缩。

## 本仓库公开什么

只包含维护者整理过的应用源码、原创图标生成器和合成离线/UI 测试。采用新提交历史，不镜像私有开发库、用户数据、旧调试分支、研究下载或聊天附件。

当前快照版本 **0.5.3**，包含全屏播放器、显式播放偏好依赖、歌单读取截止与部分详情复用、原生 JS 副本选择与隔离、网易云云端喜欢/歌单/可选听歌上报、Emby 和 Navidrome/Subsonic 连接。

新增：服务器曲目缺图时，按歌名和歌手调用 `https://api.lrc.cx/cover`；歌曲列表、迷你播放器、全屏播放器与系统媒体封面共用派生地址及受限下载器。Emby/Navidrome/Subsonic 播放页接入 `https://api.lrc.cx/lyrics`，支持 LRC 滚动与纯文本、来源标识和手动重试。外部匹配可能命中不同版本，不保证每首歌均有封面/歌词。当前不读取带服务器鉴权的原始封面，也不按歌单名伪造歌单封面。

**播放与验证边界**：网易云原生 v1 播放地址请求迁移到 XEAPI：匿名公钥协商、响应签名验证、X25519/HKDF/AES-GCM 请求密钥封装、C/S/R 请求与 AES/gzip 响应解包。公钥仅在当前客户端内存中缓存，退出账号即清理；不会保存服务端会话密钥、自动重试拒绝请求、换身份或绕过会员/版权限制。其他账号和歌单接口仍用 EAPI；旧标准模式保留 WEAPI，须用户手动选择。诊断区分公钥协商与播放请求，只展示固定路由和数值状态。离线夹具通过或 Release 编译成功均不证明真实账号播放已恢复，不能仅凭协议迁移声称解决了 `-460`。部分真实设备文件提供方交互仍待验证；以对应 Actions 结果和真实设备反馈为准。

## 构建

- 标准 GitHub-hosted `macos-26` 运行器，Xcode 26；不使用付费大型运行器。
- 权限默认 `contents: read`，Checkout 不持久化凭据，不需要添加专用 PAT 或签名证书。
- 先运行合成协议/状态机检查，构建 Release，再做 iOS 模拟器 UI 验证。
- Release 编译和打包成功后立即上传 unsigned IPA；模拟器 UI 测试随后运行，仍是独立门禁，失败会让工作流保持失败。使用前查看对应 Actions 运行结果。公开工作流不上传 UI 截图、录屏、UI 层级文本或 Xcode result bundle；普通构建/测试日志对公众可见。
- IPA 无签名、无 provisioning profile，须自行签名；App 不会静默安装。
- 公开仓库的构建日志和上传产物可被他人查看。标准运行器是否能够启动仍取决于 GitHub 当时的账户和服务状态。

本地 macOS：

```sh
brew install xcodegen
xcodegen generate --spec project.yml
python3 scripts/prepare_picker_fixture.py
bash scripts/check_native.sh
xcodebuild -project TingFlow.xcodeproj -scheme TingFlow -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

调试文件选择器夹具的文件共享配置仅用于 Debug，Release 不开启文件共享。`#if DEBUG` 演示歌曲和原创几何封面不进入 Release。

## 数据与安全

- 不包含个人 Cookie、密码、GitHub PAT、真实服务器地址、签名媒体链接或用户上传的 JS。
- 平台凭据仅放设备钥匙串；音源不会收到网易云或服务器凭据。音源默认隔离，明确审阅信任及授权 HTTPS 域名后才运行。
- 云端写入只来自用户主动操作，写后读回确认；听歌上报默认关闭，不补报旧本机历史，不保证官方即时显示或计数。
- 所有测试使用虚构账号与 `example.invalid` 等合成地址，不向真实账号执行写入。
- 封面/歌词补全只向 `api.lrc.cx` 发送歌名与歌手，不发送服务器地址、曲目 ID、Cookie 或 Token；该第三方将获知所查询的歌名/歌手及网络地址。图片可重定向至受限 HTTPS 图片域名（含 `mzstatic.com`），不使用平台认证会话。仅内存缓存，歌词不随音乐库持久化。
- 若后续贡献，请勿上传用户歌单、服务器导出、Cookie、截图或带令牌日志。

## 参考与许可

接口/协议参考 Kumone、NeteaseCloudMusicApi Enhanced、LX Music 和官方 Subsonic/OpenSubsonic 文档；不捆绑下载的研究仓库或预编译库。XEAPI 互操作模块按 MIT 许可改编自 NeteaseCloudMusicApiEnhanced/api-enhanced 的明确快照，模块保留完整许可及归属；此项许可不覆盖本项目其他文件。参见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目许可证状态与第三方参考范围尚未完成正式法律审查；仓库保持无许可证声明，不自动推定任何开源许可。

公开可读不等于将本项目授予 MIT 或其它开源许可。未附许可授予前，原有版权及第三方各自权利不变；GitHub 平台规定的浏览/fork权限除外。使用第三方服务须遵守其条款及你自己的账号/内容授权。
