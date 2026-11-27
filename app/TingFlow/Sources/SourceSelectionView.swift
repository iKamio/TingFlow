import SwiftUI

struct SourceSelectionView: View {
    @ObservedObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    var replay: (() -> Void)? = nil
    var body: some View {
        List {
            Section("播放解析音源") {
                choice(.automatic, title: "自动", detail: "网易云优先使用平台结果；需要 JS 解析时按启用顺序尝试。不绕过平台安全拒绝。")
                ForEach(store.sources) { source in
                    choice(.source(source.id), title: source.name,
                           detail: source.isEnabled && source.isTrusted ? source.statusText : "未启用或尚未信任 · 请先到音源管理授权")
                        .disabled(!source.isEnabled || !source.isTrusted || store.isBusy)
                }
                if store.sources.isEmpty { Text("还没有导入音源。导入后仍需审阅脚本并授权精确域名。") }
            }
            Section {
                Text("歌曲平台是搜索结果的归属；解析音源是取得播放地址的脚本，两者不是一回事。手动选择仅影响已开启 JS 解析的网易云和酷狗，不改变 Emby 或音乐服直连；只尝试该音源，不会悄悄更换。网易云仍先检查平台安全拒绝；无可用地址不代表歌曲没有版权限制。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { SourceManagerView(store: store) } label: { Label("管理、导入与授权音源", systemImage: "doc.badge.gearshape") }
                if let replay {
                    Button("用当前选择重新播放此曲") { dismiss(); replay() }
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("source-replay")
                }
            }
            if !store.attempts.isEmpty {
                Section("最近一次解析 · 不含地址或令牌") {
                    ForEach(store.attempts) { attempt in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(attempt.name).font(.headline); Spacer(); Text(attempt.platform.title).font(.caption) }
                            Text(attempt.message).font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.navigationTitle("选择播放音源")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .accessibilityIdentifier("source-selection-page")
    }
    private func choice(_ selection: SourceSelection, title: String, detail: String) -> some View {
        Button { store.selection = selection } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if store.selection == selection { Image(systemName: "checkmark").foregroundStyle(.pink) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.isBusy)
            .accessibilityValue(store.selection == selection ? "已选择" : "未选择")
    }
}
