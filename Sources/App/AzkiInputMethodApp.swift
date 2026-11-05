// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct AzkiInputMethodApp: App {
    @StateObject private var settings = AzkiSettings()
    @StateObject private var voice = VoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            AzkiHomeView()
                .environmentObject(settings)
                .preferredColorScheme(settings.preferences.theme.colorScheme)
                .safeAreaInset(edge: .top, spacing: 0) { VoiceBanner(recorder: voice) }
                .onChange(of: scenePhase) { if $0 == .active { settings.reload() } }
                .onOpenURL { voice.open($0) }
        }
    }
}

struct AzkiCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ContinuousRoundedRectangle(cornerRadius: 20).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}

struct LanguageChoices: View {
    @EnvironmentObject private var settings: AzkiSettings
    var body: some View {
        HStack(spacing: 8) {
            ForEach(KeyboardLanguage.allCases, id: \.rawValue) { language in
                AzkiButton(id: "language.\(language.rawValue)", title: language.displayName,
                           systemImage: settings.preferences.language == language ? "checkmark" : nil) {
                    settings.update { $0.language = language }
                }
            }
        }
    }
}

struct DictionaryView: View {
    @EnvironmentObject private var settings: AzkiSettings
    @State private var importing = false
    @State private var confirmRestore = false
    var body: some View {
        AzkiCard(title: "自定义词库") {
            Text("\(settings.entryCount) 条自定义词").font(.title2.bold()).accessibilityIdentifier("DictionaryCount")
            Text(settings.status).font(.callout).accessibilityIdentifier("DictionaryStatus")
            HStack {
                AzkiButton(id: "import", title: "从文件导入 TSV", systemImage: "square.and.arrow.down") { importing = true }
                AzkiButton(id: "restore", title: "恢复上次", systemImage: "arrow.uturn.backward") { confirmRestore = true }
            }
            Text("格式：reading[TAB]text[TAB]language[TAB]weight\nnihao\t你好\tzh\t100\nhello\thello\ten\t100\nkonnichiha\tこんにちは\tja\t100")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.tabSeparatedText, .plainText, .data]) { result in
            switch result {
            case .success(let url): settings.importFile(url)
            case .failure(let error): settings.report("未导入：\(error.localizedDescription)")
            }
        }
        .alert("恢复上次导入前的配置？", isPresented: $confirmRestore) {
            Button("恢复", role: .destructive) { settings.restorePrevious() }
            Button("取消", role: .cancel) {}
        } message: { Text("词库、短语和外观都会恢复") }
    }
}

struct PhraseEditorView: View {
    @EnvironmentObject private var settings: AzkiSettings
    @State private var editingID: String?
    @State private var title = ""
    @State private var text = ""
    @State private var abbreviation = ""
    var body: some View {
        AzkiCard(title: editingID == nil ? "添加快捷短语" : "编辑快捷短语") {
            TextField("标题", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("PhraseTitle")
            TextField("内容", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).accessibilityIdentifier("PhraseText")
            TextField("缩写（可选）", text: $abbreviation).textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("PhraseAbbreviation")
            HStack {
                AzkiButton(id: "phrase.save", title: editingID == nil ? "添加" : "保存", systemImage: "plus") { save() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty)
                AzkiButton(id: "phrase.cancel", title: "清空") { reset() }
            }
        }
        AzkiCard(title: "已保存短语 · \(settings.preferences.phrases.count)") {
            ForEach(settings.preferences.phrases, id: \.id) { phrase in
                VStack(alignment: .leading, spacing: 8) {
                    Text(phrase.title).font(.headline)
                    if let code = phrase.abbreviation { Text("缩写：\(code)").font(.caption).foregroundStyle(.secondary) }
                    Text(phrase.text).font(.callout).textSelection(.enabled)
                    HStack {
                        AzkiButton(id: "phrase.edit.\(phrase.id)", title: "编辑", systemImage: "pencil") {
                            editingID = phrase.id; title = phrase.title; text = phrase.text; abbreviation = phrase.abbreviation ?? ""
                        }
                        AzkiButton(id: "phrase.delete.\(phrase.id)", title: "删除", systemImage: "trash", role: .destructive) {
                            settings.update { $0.phrases.removeAll { $0.id == phrase.id } }
                            if editingID == phrase.id { reset() }
                        }
                    }
                    Divider()
                }
            }
        }
    }
    private func save() {
        let phrase = QuickPhrase(id: editingID ?? UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: text,
                                 abbreviation: QuickPhrase.normalizedAbbreviation(abbreviation))
        settings.update {
            if let index = $0.phrases.firstIndex(where: { $0.id == phrase.id }) { $0.phrases[index] = phrase }
            else { $0.phrases.append(phrase) }
        }
        reset()
    }
    private func reset() { editingID = nil; title = ""; text = ""; abbreviation = "" }
}

struct AboutView: View {
    var body: some View {
        AzkiCard(title: "启用 Azki输入法") {
            Text("系统设置 → 通用 → 键盘 → 键盘 → 添加新键盘，选择 Azki输入法并打开“允许完全访问”。")
            AzkiButton(id: "open.system.settings", title: "打开本应用系统设置", systemImage: "gearshape") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        }
        AzkiCard(title: "作者") {
            Text("AzumaChiaki")
            Link("azu@azki.ai", destination: URL(string: "mailto:azu@azki.ai")!)
        }
        LicenseNoticesView()
    }
}

private struct LicenseNoticesView: View {
    @State private var expanded = false
    @State private var notices = ""
    var body: some View {
        AzkiCard(title: "开源协议") {
            AzkiButton(id: "licenses", title: expanded ? "收起许可正文" : "查看随包许可正文", systemImage: "doc.text") {
                if !expanded { load() }
                expanded.toggle()
            }
            if expanded {
                Text(notices).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("LicenseNotices")
            }
        }
    }
    private func load() {
        var files: [URL] = []
        if let manifest = Bundle.main.url(forResource: "dictionary-manifest", withExtension: "json") { files.append(manifest) }
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
           let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            files += enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        }
        notices = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
            guard let body = try? String(contentsOf: $0, encoding: .utf8) else { return nil }
            return "── \($0.lastPathComponent) ──\n\(body)"
        }.joined(separator: "\n\n")
        if notices.isEmpty { notices = "未找到随包许可文件，请检查构建资源。" }
    }
}
