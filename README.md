# 听流 TingFlow

iOS 16+ 原生音乐播放器。iOS 26 使用系统 TabView、搜索 Tab 与底部播放器控件。

## 功能

- **账号与音乐源**：网易云扫码登录、Emby / Navidrome 等 Subsonic 兼容服务器连接、酷狗登录与歌单读取。
- **统一搜索**：跨平台聚合搜索、手动选源、专辑与歌单封面展示、统一列表排版。
- **资料库与浏览**：歌单、专辑、歌曲浏览与分页加载，云端喜欢 / 歌单 / 可选听歌记录同步。
- **播放**：固定交叉淡化、本机有限音频窗口分析过渡、后台播放、锁屏与控制中心控制。
- **歌词与评论**：滚动歌词、歌曲评论区，支持热门 / 最新切换与分页。
- **自定义音源**：导入 JS 音源脚本，审阅授权后可手动选择来源。

## 数据与隐私

- 平台凭据只保存在设备钥匙串，不会上传或随日志导出。
- 听歌记录同步默认关闭，只在用户主动操作时写入。
- 歌词与封面补全会把歌曲名和歌手发送给第三方服务；音乐服务器封面只访问你自己配置的服务器。
- 仓库不包含账号 Cookie、令牌、真实服务器地址、用户歌单或测试抓包数据。

## 构建

需要 macOS 与 Xcode：

```sh
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project TingFlow.xcodeproj -scheme TingFlow -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

产物为无签名 IPA，需自行签名后安装。仓库自带合成测试，不依赖真实账号。

## 许可与第三方参考

接口实现参考公开的网易云、Subsonic 与 LX 生态项目，归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本项目尚未确定开源许可，公开可读不代表授权他人使用第三方服务的接口，请自行遵守相关服务条款。
