# 听流 TingFlow — 公开构建快照

iOS 16+ 原生 SwiftUI 音乐播放器，iOS 26 使用系统 TabView、搜索 Tab、底部播放器附件与滚动收缩。

## 本仓库公开什么

只包含维护者整理过的应用源码、原创图标生成器和合成离线/UI 测试。采用新提交历史，不镜像私有开发库、用户数据、旧调试分支、研究下载或聊天附件。

当前快照版本 **0.5.1**，包含全屏播放器、显式播放偏好依赖、歌单读取截止与部分详情复用、原生 JS 副本选择与隔离、网易云云端喜欢/歌单/可选听歌上报、Emby 和 Navidrome/Subsonic 连接。

**已知未完成项**：音乐库封面与外部歌词的新改版暂未纳入此基线；部分真实设备文件提供方交互仍待验证；网易云可能返回 `-460`，本仓库不保证解决平台安全验证或版权/音质限制。没有运行测试不等于通过；以 Actions 结果和真实设备反馈为准。

## 构建

- 标准 GitHub-hosted `macos-26` 运行器，Xcode 26；不使用付费大型运行器。
- 权限默认 `contents: read`，Checkout 不持久化凭据，不需要添加专用 PAT 或签名证书。
- 先运行合成协议/状态机检查，构建 Release，再做 iOS 模拟器 UI 验证。
- **只有完整测试成功后才上传 unsigned IPA**。UI 截图均为明确标记的合成数据。
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
- 若后续贡献，请勿上传用户歌单、服务器导出、Cookie、截图或带令牌日志。

## 参考与许可

接口/协议曾参考 Kumone、NeteaseCloudMusicApi Enhanced、LX Music 和官方 Subsonic/OpenSubsonic 文档；不包含这些项目的下载源码或预编译库。参见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目许可证状态与第三方参考范围尚未完成正式法律审查；仓库保持无许可证声明，不自动推定任何开源许可。

公开可读不等于将本项目授予 MIT 或其它开源许可。未附许可授予前，原有版权及第三方各自权利不变；GitHub 平台规定的浏览/fork权限除外。使用第三方服务须遵守其条款及你自己的账号/内容授权。
