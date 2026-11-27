# api-enhanced 匹配服务

听流保留原生网易云登录和播放接口。可选匹配服务独立运行在你自己的服务器上，iOS App 不会执行 api-enhanced 的 Node.js 代码。

## 服务端

1. 按 [api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced) 的部署说明启动服务。
2. 使用公网域名和有效 HTTPS 证书。基础地址可带部署路径，例如 `https://music.example.com/netease`；不要填写接口路径、Cookie、Token 或查询参数。
3. 保持 `ENABLE_GENERAL_UNBLOCK=false`，避免将其它原生播放请求偷偷改成匹配结果。听流会单独调用 `/song/url/match`。
4. 为接口配置限流，并检查服务端日志和上游可用性。上游版本及模块随时可能变化；应锁定并测试依赖版本。

本次核对的 api-enhanced 提交为 `23d9e9d7ee5dfeccfc3b15916ccd9da1f76d3ea4`，其锁文件使用 `@neteasecloudmusicapienhanced/unblockmusic-utils@0.4.5`。
该版本自动匹配可能等待较久；utils `0.4.6` 提供了并行匹配和模块超时。升级时需在自建部署中明确锁定并验证，不能假定锁文件会自动更新。
听流客户端请求超时为 12 秒、资源总时限为 18 秒；客户端取消不保证服务端任务已停止。

## App 配置

进入“账号与服务器设置”中的“音质与界面”，打开“播放与界面”页面：

1. 在“网易云匹配服务 · api-enhanced”确认预填的 `https://api-enhanced-psi-khaki.vercel.app`，或填写自己的 HTTPS 基础地址并点击“保存服务地址”。保存只校验地址格式，不代表网络已验证。升级保留已有保存的配置，包括主动清空的地址。
2. 新配置预选 `msls`，也可选择“自动匹配”或服务实际支持的其它模块。当前列出 `unm`、`byfuns`、`ddyr`、`gdmusic`、`msls`、`oi`、`qijieya`；服务版本不支持时应换用其它模块。
3. 开启“平台无完整音频时尝试匹配”。服务默认关闭，开启后才会发送匹配请求。

2026-11-27 对预填部署的匿名检查：首页、版本和歌曲详情接口正常，版本接口报告 `4.41.1`。匹配接口响应结构与 App 兼容。歌曲 ID `347230` 的 `msls`、`qijieya` 返回 HTTPS 音频；禁止重定向的 `Range: bytes=0-31` 请求均返回 `206`、正确的 `Content-Range` 和 32 字节音频数据。抽样自动匹配及部分其它模块返回 HTTP 音频且 `proxyUrl` 为空，另有请求失败或超时，因此新配置预选 `msls`。该检查仅验证抽样地址的传输兼容性，未验证完整播放、版本或完整性。HTTP 来源仍需服务端提供有效 HTTPS 音频代理，App 不会降低传输安全要求。

请求示例：

```http
GET https://music.example.com/song/url/match?id=歌曲的网易云数字ID&noCookie=true&source=unm
Accept: application/json
```

自动匹配时省略 `source`。实际响应格式是 URL 字符串，而非原生播放接口的数据数组：

```json
{"code":200,"data":"https://audio.example.com/track.mp3","proxyUrl":""}
```

`/song/url/v1?unblock=true` 也有匹配分支，但其响应可能将格式写成 `flac`、级别写成请求值。听流不使用这些字段判断实际音质，而显示“匹配音频 · 音质未验证”。
API 参考：[`song_url_match.js`](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/23d9e9d7ee5dfeccfc3b15916ccd9da1f76d3ea4/module/song_url_match.js)、[`song_url_v1.js`](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/23d9e9d7ee5dfeccfc3b15916ccd9da1f76d3ea4/module/song_url_v1.js)。

## 播放顺序与限制

- 优先使用网易云实际提供的完整音频。
- 手动选择 JS 音源时保持该选择，失败不会悄悄换到匹配服务。
- 自动选源时，平台无音频则先试已启用的用户脚本，再试已开启的匹配服务。平台仅提供试听时也可尝试；全部失败则保留并标识原试听。
- 登录、安全验证、限流、TLS、DRM 或取消错误不触发匹配。
- 仅接收 HTTPS 音频，禁止账号信息、私网 IP 和重定向。服务提供有效 HTTPS `proxyUrl` 时优先使用；HTTP 来源或需要跳转的来源应由服务端代理，代理必须正确支持音频 Range、Content-Range 和 Content-Type。
- 不把 HTTP 地址简单改写成 HTTPS，不把 HLS/DASH 当作渐进式音频，也不把匹配结果记成网易云原生播放历史。
- 听流不会把网易云 Cookie 交给该服务。服务端会使用歌曲 ID 查询其它音源；请先了解服务运营者和上游的数据处理方式。

灰色状态可能涉及版权、地区、会员或目录状态。匹配成功只表示服务返回了一个地址，无法证明它是原版、完整版本或你有播放权；周杰伦等具体曲目仍取决于来源实际可用性。
