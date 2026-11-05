// SPDX-License-Identifier: MIT
import SwiftUI

/// Optional, local-first personalisation shared by the app and keyboard:
/// a selected regional dialect pack and bounded candidate memory.
struct IntelliSenseView: View {
    @EnvironmentObject private var settings: AzkiSettings
    private let catalog = DialectCatalog.bundled()
    @State private var confirmClear = false

    private var regions: [DialectRegion] { catalog?.regions ?? [] }
    private var selectedRegion: DialectRegion? {
        guard let id = settings.preferences.dialectRegionID else { return nil }
        return regions.first { $0.id == id }
    }
    private var families: [String] {
        var seen = Set<String>()
        return regions.compactMap { seen.insert($0.family).inserted ? $0.family : nil }
    }

    private func preference(_ path: WritableKeyPath<AzkiPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { settings.preferences[keyPath: path] }, set: { value in settings.update { $0[keyPath: path] = value } })
    }

    var body: some View {
        AzkiCard(title: "输入方式") {
            LabeledContent("中文字形") {
                Picker("中文字形", selection: Binding(get: { settings.preferences.chineseScript },
                                                  set: { value in settings.update { $0.chineseScript = value } })) {
                    ForEach(ChineseScript.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("ChineseScript")
            }
            Toggle("滑行输入", isOn: preference(\.glideTyping)).accessibilityIdentifier("GlideTyping")
            Toggle("上滑输入数字和符号", isOn: preference(\.flickInput)).accessibilityIdentifier("FlickInput")
            Toggle("表情推荐", isOn: preference(\.emojiSuggestions)).accessibilityIdentifier("EmojiSuggestions")
        }
        AzkiCard(title: "方言优化") {
            Toggle("根据所在地区优化候选", isOn: dialectBinding)
                .accessibilityIdentifier("DialectEnabled")
            if catalog == nil {
                Text("内置方言数据不可用，请检查应用资源。")
                    .font(.caption).foregroundStyle(.orange)
            } else if settings.preferences.dialectEnabled {
                Menu {
                    ForEach(families, id: \.self) { family in
                        Section(family) {
                            ForEach(regions.filter { $0.family == family }) { region in
                                Button {
                                    settings.update { $0.dialectRegionID = region.id }
                                } label: {
                                    if settings.preferences.dialectRegionID == region.id {
                                        Label(region.name, systemImage: "checkmark")
                                    } else {
                                        Text(region.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("地区").foregroundStyle(.primary)
                        Spacer()
                        Text(selectedRegion?.name ?? "请选择地区")
                            .foregroundStyle(selectedRegion == nil ? .secondary : .primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("DialectRegionPicker")
                .accessibilityLabel("方言地区")
                .accessibilityValue(selectedRegion?.name ?? "未选择")
            }
        }
        AzkiCard(title: "输入记忆") {
            Toggle("学习我的选词与组词习惯", isOn: learningBinding)
                .accessibilityIdentifier("LearningEnabled")
            Text("已学习 \(settings.learnedCount) 条本机词条")
                .font(.headline).monospacedDigit()
                .accessibilityIdentifier("LearnedCount")
            if !settings.memoryStatus.isEmpty {
                Text(settings.memoryStatus).font(.caption).foregroundStyle(.secondary)
            }
            AzkiButton(id: "clear.input.memory", title: "清除本机输入记忆", systemImage: "trash", role: .destructive) {
                confirmClear = true
            }
        }
        .alert("清除本机输入记忆？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) { settings.clearInputMemory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销")
        }
    }

    private var dialectBinding: Binding<Bool> {
        Binding(get: { settings.preferences.dialectEnabled },
                set: { value in settings.update { $0.dialectEnabled = value } })
    }

    private var learningBinding: Binding<Bool> {
        Binding(get: { settings.preferences.learningEnabled },
                set: { value in settings.update { $0.learningEnabled = value } })
    }
}
