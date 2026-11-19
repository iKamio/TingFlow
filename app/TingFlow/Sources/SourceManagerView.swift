import SwiftUI

private enum SourceManagerModal: Identifiable {
    case picker(UUID), paste(UUID), trust(UserSource)
    var id: String {
        switch self {
        case .picker(let id): return "picker-\(id)"
        case .paste(let id): return "paste-\(id)"
        case .trust(let source): return "trust-\(source.id)"
        }
    }
}
private enum SourceImportStage {
    case idle, selecting, reading, failed(String)
}

@MainActor struct SourceManagerView: View {
    @ObservedObject var store: SourceStore
    @State private var modal: SourceManagerModal?
    @State private var selectedURL: URL?
    @State private var afterDismissNotice: String?
    @State private var hostText = ""
    @State private var notice: String?
    @State private var stage: SourceImportStage = .idle
    @State private var policy = SourcePickerPolicy()
    @State private var importTask: Task<Void, Never>?
    @State private var moving: UUID?
    private var isReading: Bool { policy.phase == .reading }
    private let importedMessage = "音源已导入并隔离；尚未运行。请阅读脚本、确认信任并只授权所需域名。"
    var body: some View {
        List {
            Section {
                Button {
                    cancelRead(); selectedURL = nil; afterDismissNotice = nil
                    let ticket = policy.begin(); stage = .selecting; modal = .picker(ticket)
                } label: {
                    HStack { Label("导入洛雪 JavaScript 音源", systemImage: "plus"); Spacer(); if isReading { ProgressView() } }
                }.accessibilityIdentifier("source-import").disabled(isReading || modal != nil)
                Button("粘贴 JavaScript 文本") {
                    cancelRead(); stage = .idle; modal = .paste(UUID())
                }.accessibilityIdentifier("source-import-paste").disabled(isReading || modal != nil)
                switch stage {
                case .idle: EmptyView()
                case .selecting:
                    Text("选择中 · selecting · 可先选择任意文件，再检查 .js 与内容。")
                        .font(.footnote).accessibilityIdentifier("source-import-selecting")
                case .reading:
                    Text("读取中 · reading · 正在复制并校验；最长 15 秒，不执行脚本。")
                        .font(.footnote).accessibilityIdentifier("source-import-reading")
                    Button("取消读取", role: .cancel) { cancelRead(); stage = .idle }
                        .accessibilityIdentifier("source-import-cancel")
                case .failed(let message):
                    Text("导入失败 · failed：\(message)").font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("source-import-failed")
                    Button("清除错误", role: .cancel) { stage = .idle; notice = nil }
                        .accessibilityIdentifier("source-import-clear")
                }
                Text("脚本仅在本机运行，不共享网易云 Cookie 或 Emby Token。导入后默认隔离，需单独信任、授权 HTTPS 域名并启用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.sources.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "doc.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有自定义音源").font(.headline)
                    Text("选取自己信任的 .js 源。导入后先隔离，确认权限再运行。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            }
            ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, source in
                sourceRow(source, index: index)
            }
            Section("兼容性与安全") {
                Text("基于 LX mobile 2.0 子集；不是 Node/Electron 环境。尚未提供 Node、浏览器、WebSocket、文件系统、Cookie、multipart、binary 或任意原生 API。")
                Text("公有 JavaScriptCore 不能硬中断死循环，不提供 CPU／内存隔离保证。只运行已审查的可信脚本；超时或取消时若 JS 仍在执行，相同哈希禁止重跑，需重启应用。来源声明不代表平台授权，也不保证 VIP、DRM 或所有曲目可播。")
                Text("精确域名白名单不等于完整局域网防护：URLSession 无法可靠防御 DNS 重绑定。请求音质只表示传给脚本的档位，不证明返回音频的编码、码率或可播放性。AES 支持 CBC/PKCS7 与 ECB/无填充；RSA 明确不支持。")
                if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("自定义音源")
        // One presentation owner for native selection, explicit paste and trust.
        // Reading starts only in onDismiss, after UIKit has relinquished the modal.
        .sheet(item: $modal, onDismiss: modalDismissed) { route in
            switch route {
            case .picker(let ticket):
                SourceDocumentPicker { result in
                    guard ticket == policy.id, policy.phase == .selecting else { return }
                    switch result {
                    case .success(let url):
                        if let url, policy.selected(ticket) { selectedURL = url }
                        else { policy.cancel(); stage = .idle }
                    case .failure(let error):
                        policy.cancel(); stage = .failed(error.localizedDescription)
                        afterDismissNotice = error.localizedDescription
                    }
                    modal = nil
                }
            case .paste:
                SourcePasteImportView { file in
                    try store.importScript(file.data, filename: file.filename)
                    stage = .idle; afterDismissNotice = importedMessage; modal = nil
                } cancel: { modal = nil }
            case .trust(let source):
                trustView(source)
            }
        }
        .onDisappear {
            cancelRead(); selectedURL = nil; modal = nil; stage = .idle
        }
        .alert("音源管理", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }
    private func cancelRead() {
        policy.cancel(); importTask?.cancel(); importTask = nil
    }
    private func modalDismissed() {
        hostText = ""
        if let message = afterDismissNotice {
            afterDismissNotice = nil; notice = message
        }
        guard let url = selectedURL, policy.phase == .reading else {
            selectedURL = nil
            if policy.phase == .selecting { policy.cancel(); stage = .idle }
            return
        }
        selectedURL = nil
        let ticket = policy.id; stage = .reading
        importTask = Task { @MainActor in
            do {
                let file = try await SourceFileImport.read(url)
                try Task.checkCancellation()
                guard policy.finish(ticket) else { return }
                importTask = nil
                try store.importScript(file.data, filename: file.filename)
                stage = .idle; notice = importedMessage
            } catch {
                // finish is intentionally called before committing to the store. A
                // store error is still visible, but stale/cancelled workers stay silent.
                guard ticket == policy.id else { return }
                _ = policy.finish(ticket); importTask = nil
                if SourceImportFailure.isCancellation(error) { stage = .idle; return }
                let message = (error as? SourceImportFailure)?.localizedDescription ??
                    (error as? SourceFailure)?.localizedDescription ?? SourceFailure.storage.localizedDescription
                stage = .failed(message); notice = message
            }
        }
    }
    private func trustView(_ source: UserSource) -> some View {
        NavigationStack {
            Form {
                Section("即将信任：\(source.name)") {
                    LabeledContent("作者", value: source.author)
                    LabeledContent("版本", value: source.version)
                    Text(source.description).foregroundStyle(.secondary)
                    NavigationLink("查看原始脚本（不执行）") { codeView(source) }
                    Text("授权后将运行任意 JavaScript。宿主不能硬中断死循环，也不能可靠防御 DNS 重绑定；请先审阅完整代码。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("明确授权 HTTPS 主机") {
                    TextField("api.example.com, cdn.example.com", text: $hostText, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("source-hosts")
                    Text("只输入主机名，不带协议、路径、通配符或端口。应用阻止 HTTP、所有重定向和 Cookie。域名应对应你信任的音源源代码。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section { Text("同意意味着允许运行这份脚本；脚本来源及平台条款仍由你负责。可随时停用或删除。")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("审阅并授权")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { modal = nil; hostText = "" } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("信任并启用") {
                        do { try store.trust(source.id, hosts: hostText) }
                        catch { afterDismissNotice = (error as? SourceFailure)?.localizedDescription ?? SourceFailure.permission.localizedDescription }
                        modal = nil; hostText = ""
                    }.disabled(hostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.presentationDetents([.medium, .large])
    }
    @ViewBuilder private func codeView(_ source: UserSource) -> some View {
        if let raw = try? store.scriptText(source.id) {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("SHA-256：\(source.sha256)\n只读审阅，不会执行脚本。")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(raw).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: true, vertical: true)
                }.padding().textSelection(.enabled)
            }.navigationTitle("原始脚本")
        } else {
            Text("脚本无法读取或哈希已改变；不会执行。请删除后重新导入。")
                .padding().navigationTitle("无法审阅")
        }
    }
    @ViewBuilder private func sourceRow(_ source: UserSource, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: source.state == .ready ? "checkmark.shield.fill" : "doc.text.fill")
                    .font(.title3).foregroundStyle(source.state == .ready ? .green : .pink)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.headline)
                    Text("\(source.author) · v\(source.version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("启用", isOn: Binding(get: { source.isEnabled && source.isTrusted }, set: { store.setEnabled(source.id, $0) }))
                    .labelsHidden().disabled(!source.isTrusted)
            }
            Text(source.statusText).font(.caption).foregroundStyle(.secondary)
            NavigationLink("查看原始脚本（不执行）") { codeView(source) }
                .font(.caption)
            if source.isTrusted {
                Button("重新审阅与修改域名") {
                    guard !isReading, modal == nil else { return }
                    modal = .trust(source); hostText = source.allowedHosts.joined(separator: ", ")
                }.font(.caption).disabled(isReading || modal != nil)
                Text("授权域名：\(source.allowedHosts.joined(separator: ", "))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(source.capabilities.isEmpty ? "平台/音质声明尚未验证" : source.capabilities.sorted(by: { $0.key < $1.key }).map { key, value in
                    "\(key)：\(value.qualitys.joined(separator: ", "))"
                }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("上移") { store.move(source.id, offset: -1) }.disabled(index == 0)
                    Button("下移") { store.move(source.id, offset: 1) }.disabled(index + 1 == store.sources.count)
                    Spacer()
                    Button("删除", role: .destructive) { store.delete(source.id) }
                }.font(.caption)
            } else {
                Button("审阅脚本并授权域名") {
                    guard !isReading, modal == nil else { return }
                    modal = .trust(source); hostText = ""
                }.font(.subheadline.weight(.semibold)).disabled(isReading || modal != nil)
                Button("删除此隔离文件", role: .destructive) { store.delete(source.id) }
                    .font(.caption)
            }
        }.padding(.vertical, 5)
    }
}

/// No UIPasteboard access: only a user's own TextEditor typing/paste operation
/// supplies text. Importing here uses the exact same quarantine-only store API.
@MainActor private struct SourcePasteImportView: View {
    let submit: (SourceImportFile) throws -> Void
    let cancel: () -> Void
    @State private var filename = "我的音源.js"
    @State private var text = ""
    @State private var error: String?
    private var bytes: Int { text.utf8.count }
    var body: some View {
        NavigationStack {
            Form {
                Section("手动粘贴 JavaScript 文本") {
                    Text("应用不会自动读取剪贴板。请长按下方编辑框并自行粘贴，或手动输入脚本。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("文件名（必须以 .js 结尾）", text: $filename)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("source-paste-filename")
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 220).accessibilityIdentifier("source-paste-text")
                    Text("UTF-8：\(bytes) / \(SourceFileImport.maximumBytes) 字节（1 MiB）")
                        .font(.caption).foregroundStyle(bytes > SourceFileImport.maximumBytes ? .red : .secondary)
                }
                if let error {
                    Section("导入失败 · failed") {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("source-paste-error")
                        Button("清除错误") { self.error = nil }
                    }
                }
                Section { Text("仅校验 .js 文件名、UTF-8 与 1 MiB 上限并导入隔离区；不会执行、信任或启用脚本。")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("粘贴音源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入并隔离") {
                        do { try submit(SourceFileImport.pasted(text, filename: filename)) }
                        catch {
                            self.error = (error as? SourceImportFailure)?.localizedDescription ??
                                (error as? SourceFailure)?.localizedDescription ?? SourceFailure.storage.localizedDescription
                        }
                    }.accessibilityIdentifier("source-paste-submit")
                }
            }
        }.interactiveDismissDisabled(!text.isEmpty)
    }
}
