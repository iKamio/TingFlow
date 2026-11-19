import SwiftUI

struct UpdateView: View {
    @StateObject private var store = UpdateStore()
    var body: some View {
        Form {
            Section("当前版本") {
                LabeledContent("听流", value: "\(store.currentVersion)（\(store.currentBuild)）")
                Button { Task { await store.check() } } label: {
                    HStack { Text("检查更新"); Spacer(); if store.isChecking { ProgressView() } }
                }.disabled(store.isChecking)
                if let message = store.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if store.hasNewVersion, let update = store.manifest {
                Section("新版本") {
                    Text("\(update.version) · build \(update.build)").font(.headline)
                    Text(update.notes).font(.subheadline)
                    Link("打开下载页并自行签名", destination: update.pageURL)
                    Text("IPA 需用你的签名工具覆盖安装；普通侧载 App 不能自行替换或静默安装。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("更新清单") {
                TextField("https://你的站点/tingflow.json", text: $store.manifestAddress, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存清单地址") { store.saveAddress() }.disabled(store.isChecking)
                Text("可使用可信 HTTPS JSON 更新清单比较版本；未配置时会明确提示，不会伪称“已是最新”。公开仓库中的构建产物需要自行签名安装。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("公开构建") {
                Link("打开公开构建页", destination: URL(string: "https://github.com/iKamio/TingFlow-Public/actions/workflows/ios.yml")!)
                Text("下载 Actions 构建产物可能需要 GitHub 登录。应用不存 GitHub 令牌；公开仓库不会包含你的账号、服务器地址或私人歌单。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("检查更新")
    }
}
