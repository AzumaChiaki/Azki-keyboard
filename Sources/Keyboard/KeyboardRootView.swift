// SPDX-License-Identifier: MIT
import SwiftUI

@MainActor
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    let pasteContext: KeyboardPasteContext
    @EnvironmentObject private var settings: AzkiSettings

    private var metrics: KeyboardMetrics { model.metrics }

    var body: some View {
        GeometryReader { geometry in
            // The bar owns the insets around it, so candidates can use them as touch area.
            VStack(spacing: 0) {
                toolbar.frame(height: metrics.topInset + metrics.candidateHeight + metrics.barGap)
                Group {
                    switch model.panel {
                    case .keys, .addPhrase:
                        keyGrid(width: min(geometry.size.width, 980) - metrics.sideInset * 2)
                            .environment(\.colorScheme, keycapColorScheme)
                    case .languages: languages
                    case .quick: quickPanel
                    case .candidates: expandedCandidates
                    case .restoreDraft: draftRecoveryPanel
                    case .voice: voicePanel
                    }
                }
                .frame(height: metrics.gridHeight)
            }
            .padding(.horizontal, metrics.sideInset)
            .padding(.bottom, metrics.bottomInset)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay { GlideTrailView(trail: model.glideTrail) }
        .overlay(alignment: .topLeading) {
            if let popup = model.variantPopup {
                KeyVariantPopupView(popup: popup).environment(\.colorScheme, keycapColorScheme)
            }
        }
        .environment(\.colorScheme, model.hostColorScheme)
        .coordinateSpace(name: Self.keyboardSpace)
        .onPreferenceChange(KeyHitsPreference.self) { hits in
            MainActor.assumeIsolated { model.keyHits = hits }
        }
        .onPreferenceChange(CandidateHitsPreference.self) { hits in
            MainActor.assumeIsolated { model.candidateHits = hits }
        }
        .onPreferenceChange(ToolbarFramesPreference.self) { frames in
            MainActor.assumeIsolated { model.toolbarFrames = frames }
        }
    }

    private static let keyboardSpace = "keyboard"
    private static let candidateSpace = "candidates"

    private var keycapColorScheme: ColorScheme { settings.preferences.theme.colorScheme ?? model.hostColorScheme }

    private var isKeyboardPanel: Bool { model.panel == .keys || model.panel == .candidates }

    private var toolbar: some View {
        HStack(spacing: 5) {
            if model.panel == .addPhrase {
                if model.isComposing { candidateBar } else { phraseFormBar }
            } else if model.panel == .quick {
                quickBar
            } else if !isKeyboardPanel {
                toolbarButton("panel_back", "", "chevron.left", "AzkiPanelBack", label: "返回键盘") { model.send(.show(.keys)) }
                    .frame(width: 44)
                Spacer(minLength: 0)
            } else if model.isComposing {
                candidateBar
            } else {
                toolbarButton("quick", "", "text.bubble", "AzkiQuick", label: "快捷输入") { model.send(.show(.quick)) }
                    .frame(width: 44)
                toolbarButton("voice", "", "mic", "AzkiVoice", label: "语音输入") { model.send(.show(.voice)) }
                    .frame(width: 44)
                Spacer(minLength: 0)
                if model.hasRecoverableDraft {
                    toolbarButton("draft_restore", "", "arrow.uturn.backward", "AzkiRecoverDraft", label: "恢复上次未提交的草稿") {
                        model.send(.show(.restoreDraft))
                    }.frame(width: 44)
                }
                toolbarButton("hide", "", "keyboard.chevron.compact.down", "AzkiHide", label: "收起键盘") {
                    model.send(.dismiss)
                }.frame(width: 44)
            }
        }
    }

    private var candidateBar: some View {
        Following(model.candidateList) { candidateBarContent }
    }

    private var candidateBarContent: some View {
        HStack(spacing: 0) {
            // The add form keeps its draft out of the host, so it is shown here instead.
            if model.panel == .addPhrase {
                Text(model.preedit)
                    .font(.system(size: metrics.functionSize))
                    .underline()
                    .lineLimit(1).truncationMode(.head)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: 120, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("AzkiPhraseComposition")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.candidates) { candidate in
                        candidateButton(candidate, inBar: true).fixedSize(horizontal: true, vertical: false)
                    }
                }
                .coordinateSpace(name: Self.candidateSpace)
                .background(CandidateRowProbe(model: model))
            }
            .hidingScrollEdgeEffect()
            if model.panel != .addPhrase {
                Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 0.5, height: metrics.candidateHeight * 0.6)
                if model.panel == .candidates {
                    toolbarButton("cancel", "", "xmark", "AzkiCancel", label: "取消未提交的输入") {
                        model.send(.cancel)
                    }.frame(width: 44)
                }
                toolbarButton("candidate_expand", "", model.panel == .candidates ? "chevron.up" : "chevron.down",
                             "AzkiCandidateExpand", label: model.panel == .candidates ? "收起候选字" : "展开候选字") {
                    model.send(.show(.candidates))
                }.frame(width: 44)
            }
        }
    }

    private var quickBar: some View {
        HStack(spacing: 4) {
            toolbarButton("panel_back", "", "chevron.left", "AzkiPanelBack", label: "返回键盘") { model.send(.show(.keys)) }
                .frame(width: 44)
            Spacer(minLength: 0)
            quickTabButton(.clipboard, "粘贴板")
            quickTabButton(.phrases, "快捷输入")
            Spacer(minLength: 0)
            toolbarButton("phrase_add", "", "plus", "AzkiPhraseAdd", label: "添加快捷输入") { model.send(.show(.addPhrase)) }
                .frame(width: 44)
                .opacity(model.quickTab == .phrases ? 1 : 0)
                .allowsHitTesting(model.quickTab == .phrases)
                .accessibilityHidden(model.quickTab != .phrases)
        }
    }

    private func quickTabButton(_ tab: QuickTab, _ title: String) -> some View {
        Button { model.quickTab = tab } label: {
            Text(title).font(.system(size: metrics.functionSize - 1))
                .padding(.horizontal, 14)
                .frame(height: metrics.candidateHeight - 6)
        }
        .buttonStyle(KeyboardCandidateStyle(id: "quick_tab_\(tab.rawValue)", highlighted: model.quickTab == tab))
        .accessibilityIdentifier("AzkiQuickTab_\(tab.rawValue)")
        .accessibilityLabel(title)
        .accessibilityAddTraits(model.quickTab == tab ? .isSelected : [])
    }

    private var phraseFormBar: some View {
        HStack(spacing: 4) {
            toolbarButton("panel_back", "", "chevron.left", "AzkiPanelBack", label: "返回快捷输入") { model.send(.show(.quick)) }
                .frame(width: 44)
            phraseFieldButton(.text, "词条", model.phraseText, "AzkiPhraseFieldText")
            phraseFieldButton(.abbreviation, "缩写", model.phraseAbbreviation, "AzkiPhraseFieldAbbreviation")
                .frame(width: 96)
            toolbarButton("phrase_save", "", "checkmark", "AzkiPhraseSave", label: "保存快捷输入") { model.send(.savePhrase) }
                .frame(width: 44)
                .disabled(!model.canSavePhrase)
        }
    }

    private func phraseFieldButton(_ field: PhraseField, _ name: String, _ value: String, _ accessibilityID: String) -> some View {
        Button { model.phraseField = field } label: {
            Text(value.isEmpty ? name : value)
                .font(.system(size: metrics.functionSize))
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1).truncationMode(.head)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metrics.candidateHeight - 6)
        }
        .buttonStyle(KeyboardCandidateStyle(id: "phrase_field", highlighted: model.phraseField == field))
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(name)
        .accessibilityValue(value)
    }

    private func keyGrid(width: CGFloat) -> some View {
        let gap = metrics.keyGap
        let keyWidth = (width - gap * 9) / 10
        let sideWidth = keyWidth * 1.35
        return VStack(spacing: metrics.rowGap) {
            Group {
                if model.page == .letters {
                    characterRow(Array("qwertyuiop").map(String.init))
                    HStack(spacing: gap) {
                        Spacer(minLength: 0)
                        ForEach(Array("asdfghjkl").map(String.init), id: \.self) { letterKey($0).frame(width: keyWidth) }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: gap) {
                        actionButton("shift", "", model.uppercase ? "shift.fill" : "shift", "AzkiShift", label: "切换大写") {
                            model.send(.shift)
                        }.frame(width: sideWidth)
                        Spacer(minLength: 0)
                        ForEach(Array("zxcvbnm").map(String.init), id: \.self) { letterKey($0).frame(width: keyWidth) }
                        Spacer(minLength: 0)
                        backspace.frame(width: sideWidth)
                    }
                } else {
                    characterRow(model.page == .numbers ? Array("1234567890").map(String.init) : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], literal: true)
                    characterRow(model.page == .numbers ? ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""] : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], literal: true)
                    HStack(spacing: gap) {
                        actionButton("symbol_page", model.page == .numbers ? "#+=" : "123", nil, "AzkiSymbolPage") {
                            model.page = model.page == .numbers ? .symbols : .numbers
                        }.frame(width: sideWidth)
                        ForEach([".", ",", "?", "!", "'"], id: \.self) { literalKey($0) }
                        backspace.frame(width: sideWidth)
                    }
                }
                bottomRow(keyWidth: keyWidth)
            }
            .frame(height: metrics.keyHeight)
        }
    }

    private var backspace: some View {
        actionButton("backspace", "", "delete.left", "AzkiBackspace", label: "删除",
                     onPressChange: model.backspacePressChanged, onSwipeLeft: model.backspaceSwiped) {
            model.backspaceTapped()
        }
    }

    private func bottomRow(keyWidth: CGFloat) -> some View {
        // Return matches the keys on the left, so Space sits on the keyboard's center line.
        let leftKeys: CGFloat = model.needsGlobe ? 3 : 2
        let sideWidth = max(36, keyWidth * (model.needsGlobe ? 1.1 : 1.35))
        let balancedWidth = sideWidth * leftKeys + metrics.keyGap * (leftKeys - 1)
        let punctuationWidth = max(32, keyWidth)
        return HStack(spacing: metrics.keyGap) {
            actionButton("symbols", model.page == .letters ? "123" : "ABC", nil, "AzkiSymbols") {
                model.send(.changePage)
            }.frame(width: sideWidth)
            if model.needsGlobe {
                actionButton("globe", "", "globe", "AzkiGlobe", label: "下一个系统键盘") {
                    model.send(.globe)
                }.frame(width: sideWidth)
            }
            actionButton("language", languageShortName, nil, "AzkiLanguageButton", label: "切换输入语言",
                         enabled: model.panel != .addPhrase) {
                model.send(.show(.languages))
            }.frame(width: sideWidth).disabled(model.panel == .addPhrase)
            actionButton("space", model.spaceTitle, nil, "AzkiSpace", typesText: true) { model.send(.space) }
            punctuationKey.frame(width: punctuationWidth)
            actionButton("return", returnTitle, nil, "AzkiReturn",
                         enabled: model.panel == .addPhrase || model.returnEnabled) { model.send(.enter) }
                .frame(width: balancedWidth - punctuationWidth - metrics.keyGap)
                .disabled(model.panel != .addPhrase && !model.returnEnabled)
        }
    }

    /// Tap for the comma; flick up for the full stop, or hold to slide across the rest.
    private var punctuationKey: some View {
        let marks: (String, String) = switch model.language {
        case .chinese: ("，", "。")
        case .english: (",", ".")
        case .japanese: ("、", "。")
        }
        return actionButton("punctuation", marks.0 + marks.1, nil, "AzkiPunctuation",
                            label: "逗号，上滑输入句号，按住滑动选择其他标点",
                            variants: KeyVariants.punctuation(language: model.language),
                            onVariant: { model.send(.punctuation($0)) }, flick: marks.1,
                            onFlick: { model.send(.punctuation($0)) }, typesText: true) {
            model.send(.punctuation(marks.0))
        }
    }

    private var returnTitle: String {
        guard model.panel == .addPhrase else { return model.returnTitle }
        return model.phraseField == .text ? "下一项" : "保存"
    }

    private var languageShortName: String {
        switch model.language {
        case .chinese: return model.script.shortTitle
        case .english: return "EN"
        case .japanese: return "あ"
        }
    }

    private func characterRow(_ values: [String], literal: Bool = false) -> some View {
        HStack(spacing: metrics.keyGap) {
            ForEach(values, id: \.self) { value in
                if literal { literalKey(value) } else { letterKey(value) }
            }
        }
    }

    private func letterKey(_ letter: String) -> some View {
        let text = model.uppercase ? letter.uppercased() : letter
        return actionButton(letter, text, nil, "AzkiKey_\(letter)", textSize: metrics.letterSize,
                            onGapTouch: { model.send(.type(text, alternatives: $0)) },
                            variants: KeyVariants.letter(letter, language: model.language, uppercase: model.uppercase),
                            onVariant: { model.send($0 == text ? .type(text) : .letterVariant($0)) },
                            flick: settings.preferences.flickInput ? KeyVariants.flick(letter, language: model.language) : nil,
                            onFlick: { model.send(.punctuation($0)) },
                            showsFlick: true,
                            glides: settings.preferences.glideTyping && model.language != .japanese && model.panel == .keys,
                            typesText: true) { model.send(.type(text)) }
    }

    private func literalKey(_ value: String) -> some View {
        actionButton("symbol_\(value)", value, nil, "AzkiSymbol_\(value)", textSize: metrics.letterSize,
                     variants: KeyVariants.symbol(value), onVariant: { model.send(.punctuation($0)) },
                     typesText: true) { model.send(.punctuation(value)) }
    }

    private func toolbarButton(_ id: String, _ title: String, _ image: String?, _ accessibilityID: String,
                               label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let image { Image(systemName: image) }
                if !title.isEmpty { Text(title).lineLimit(1).minimumScaleFactor(0.55) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(BareKeyboardToolbarStyle(id: id))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ToolbarFramesPreference.self, value: [proxy.frame(in: .named(Self.keyboardSpace))])
        })
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(label ?? title)
    }

    private func actionButton(_ id: String, _ title: String, _ image: String?, _ accessibilityID: String,
                              label: String? = nil, textSize: CGFloat? = nil,
                              enabled: Bool = true, onPressChange: ((Bool) -> Void)? = nil,
                              onSwipeLeft: (() -> Void)? = nil, onGapTouch: (([Character]) -> Void)? = nil,
                              variants: [String] = [], onVariant: ((String) -> Void)? = nil,
                              flick: String? = nil, onFlick: ((String) -> Void)? = nil, showsFlick: Bool = false,
                              glides: Bool = false, typesText: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let image { Image(systemName: image) }
                if !title.isEmpty { Text(title).lineLimit(1).minimumScaleFactor(0.55) }
            }
            // Fixed like the system keyboard: Dynamic Type must not outgrow fixed keys.
            .font(.system(size: textSize ?? metrics.functionSize))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if showsFlick, let flick {
                    Text(flick).font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 3).padding(.trailing, 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(AzkiButtonStyle(
            id: id, minimumHeight: metrics.keyHeight, horizontalPadding: 1,
            defaultBackground: id == "return" && model.returnIsAction ? Color(uiColor: .systemBlue) : nil,
            defaultForeground: id == "return" && model.returnIsAction ? Color.white : nil,
            keyboardKeycap: true,
            pressSignal: model.pressSignal(id)
        ))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: KeyHitsPreference.self, value: [
                KeyHit(id: id, frame: proxy.frame(in: .named(Self.keyboardSpace)), title: title, enabled: enabled,
                       action: action, onPressChange: onPressChange, onSwipeLeft: onSwipeLeft, onGapTouch: onGapTouch,
                       variants: variants, onVariant: onVariant, flick: flick, onFlick: onFlick, glides: glides, typesText: typesText)
            ])
        })
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(label ?? title)
    }

    /// Quick-input entries can be long or multi-line; the full text is still committed.
    private func candidateTitle(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 16 ? line.prefix(15) + "…" : line
    }

    private func candidateButton(_ candidate: KeyboardCandidate, inBar: Bool = false) -> some View {
        Button { model.send(.candidate(candidate)) } label: {
            Text(candidateTitle(candidate.text)).lineLimit(1).font(.system(size: metrics.candidateSize))
                .padding(.horizontal, 11)
                .frame(minWidth: 44, minHeight: metrics.candidateHeight)
        }
        // Candidate overrides are positional: candidate_0 ... candidate_23.
        .buttonStyle(KeyboardCandidateStyle(id: "candidate_\(candidate.id)", highlighted: candidate.id == model.candidates.first?.id,
                                            hitTop: inBar ? metrics.topInset : 0, hitBottom: inBar ? metrics.barGap : 0))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CandidateHitsPreference.self, value: !inBar ? [] : [
                KeyHit(id: "candidate_\(candidate.id)", frame: proxy.frame(in: .named(Self.candidateSpace)),
                       title: "", enabled: true, action: { [model] in model.sendCandidate(id: candidate.id) })
            ])
        })
        .accessibilityIdentifier("AzkiCandidate_\(candidate.id)")
        .accessibilityLabel(candidate.text)
        .accessibilityHint("确认候选字，读音 \(candidate.reading)")
    }

    private var expandedCandidates: some View {
        ScrollView {
            Following(model.candidateList) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 4)], spacing: 4) {
                    ForEach(model.candidates) { candidateButton($0) }
                }
            }
        }
        .hidingScrollEdgeEffect()
        .accessibilityIdentifier("AzkiExpandedCandidates")
    }

    private var languages: some View {
        VStack {
            HStack(spacing: 7) {
                ForEach(ChineseScript.allCases) { script in
                    AzkiButton(id: "language_\(script.rawValue)", title: script.title, keyboardKeycap: true) {
                        model.send(.chinese(script))
                    }.environment(\.colorScheme, keycapColorScheme)
                        .accessibilityIdentifier(script == .simplified ? "AzkiLanguage_zh" : "AzkiLanguage_\(script.rawValue)")
                }
            }
            HStack(spacing: 7) {
                ForEach([KeyboardLanguage.english, .japanese], id: \.rawValue) { language in
                    AzkiButton(id: "language_\(language.rawValue)", title: language.displayName, keyboardKeycap: true) {
                        model.send(.language(language))
                    }.environment(\.colorScheme, keycapColorScheme).accessibilityIdentifier("AzkiLanguage_\(language.rawValue)")
                }
            }
            Spacer(minLength: 0)
        }.padding(8)
    }

    @ViewBuilder
    private var quickPanel: some View {
        if model.isComposing {
            VStack {
                AzkiButton(id: "cancel", title: "取消当前输入", keyboardKeycap: true) { model.send(.cancel) }
                    .environment(\.colorScheme, keycapColorScheme)
                Spacer(minLength: 0)
            }.padding(8)
        } else {
            switch model.quickTab {
            case .clipboard: clipboardPanel
            case .phrases: phrases
            }
        }
    }

    private var phrases: some View {
        let ticket = model.ticket
        return ScrollView {
            VStack(spacing: 7) {
                ForEach(Array(settings.preferences.phrases.enumerated()), id: \.offset) { index, phrase in
                    Button { model.send(.phrase(phrase.text, ticket)) } label: {
                        HStack(spacing: 8) {
                            Text(phrase.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            if let abbreviation = phrase.abbreviation {
                                Text(abbreviation).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(AzkiButtonStyle(id: "phrase_\(index)", minimumHeight: 44, keyboardKeycap: true))
                    .environment(\.colorScheme, keycapColorScheme)
                    .accessibilityIdentifier("AzkiPhrase_\(index)")
                    .accessibilityLabel(phrase.text)
                }
            }.padding(4)
        }
        .hidingScrollEdgeEffect()
    }

    private var draftRecoveryPanel: some View {
        let ticket = model.draftConfirmationTicket
        let lease = model.draftConfirmationLease
        return VStack(spacing: 10) {
            if model.hasRecoverableDraft {
                AzkiButton(id: "draft_restore_confirm", title: "恢复到这里", systemImage: "arrow.uturn.backward", keyboardKeycap: true) {
                    model.send(.restoreDraft(ticket, lease))
                }.environment(\.colorScheme, keycapColorScheme).accessibilityIdentifier("AzkiConfirmDraftRecovery")
                AzkiButton(id: "draft_discard", title: "丢弃草稿", systemImage: "trash", keyboardKeycap: true) {
                    model.send(.discardDraft(ticket, lease))
                }.environment(\.colorScheme, keycapColorScheme).accessibilityIdentifier("AzkiDiscardSavedDraft")
            }
            Spacer(minLength: 0)
        }.padding(8)
    }

    private var voicePanel: some View {
        VStack(spacing: 10) {
            ScrollView {
                Text(model.voiceProblem ?? (model.voiceText.isEmpty ? "正在听…" : model.voiceText))
                    .font(.system(size: metrics.functionSize))
                    .foregroundStyle(model.voiceProblem == nil && !model.voiceText.isEmpty ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("AzkiVoiceText")
            }
            if model.voiceProblem == nil {
                AzkiButton(id: "voice_done", title: "完成", systemImage: "checkmark", keyboardKeycap: true) {
                    model.send(.finishVoice)
                }.environment(\.colorScheme, keycapColorScheme).accessibilityIdentifier("AzkiVoiceDone")
            }
        }.padding(8)
    }

    private var clipboardPanel: some View {
        Group {
            if model.fullAccess, let ticket = model.ticket {
                SystemPasteControl(pasteContext: pasteContext, ticket: ticket)
                    .id(ticket)
                    .frame(width: 144, height: 48)
            } else {
                Image(systemName: "doc.on.clipboard").font(.system(size: 28)).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("AzkiClipboardUnavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    /// iOS 26+ scroll views blur content at their edges; on a keyboard that
    /// covers the candidates themselves.
    @ViewBuilder
    func hidingScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// The line left by a sliding finger.
private struct GlideTrailView: View {
    @ObservedObject var trail: GlideTrail

    var body: some View {
        Path { $0.addLines(trail.points) }
            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Redraws `content` alone when `object` changes.
private struct Following<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    let content: () -> Content

    init(_ object: Object, @ViewBuilder content: @escaping () -> Content) {
        self.object = object
        self.content = content
    }

    var body: some View { content() }
}

/// The variants of a held key. Touches stay with the key, so this only draws.
private struct KeyVariantPopupView: View {
    let popup: VariantPopup

    var body: some View {
        let frame = popup.cells.reduce(CGRect.null) { $0.union($1) }
        HStack(spacing: 0) {
            ForEach(Array(popup.items.enumerated()), id: \.offset) { index, item in
                let selected = index == popup.selected
                Text(item)
                    .font(.system(size: 22))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: popup.cells[index].width, height: popup.cells[index].height)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
                    .accessibilityIdentifier("AzkiVariant_\(item)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(uiColor: .systemBackground)).shadow(color: .black.opacity(0.3), radius: 5, y: 2))
        .offset(x: frame.minX, y: frame.minY)
        .allowsHitTesting(false)
    }
}

/// Candidates are plain text on the system keyboard background. Only the
/// candidate that Space would commit carries a pill.
private struct KeyboardCandidateStyle: ButtonStyle {
    @EnvironmentObject private var settings: AzkiSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let id: String
    let highlighted: Bool
    /// Touch area beyond the visible candidate, which reaches into the bar's insets.
    var hitTop: CGFloat = 0
    var hitBottom: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let preferences = settings.preferences
        let override = preferences.keyOverrides[id]
        let customHex = scheme == .dark ? override?.darkBackground : override?.lightBackground
        let pressedHex = override?.pressedBackground ?? preferences.pressedBackground
        let highlight = Color.white.opacity(scheme == .dark ? 0.16 : 0.75)
        let resting = Color(azkiHex: customHex) ?? (highlighted ? highlight : Color.clear)
        let background = pressed ? Color(azkiHex: pressedHex) ?? resting : resting
        let filledHex = pressed ? pressedHex : customHex
        let foreground = filledHex.flatMap { RGBColor(hex: $0) }.flatMap { Color(azkiHex: $0.readableForeground.hex) } ?? .primary
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay(shape.stroke(Color.primary, lineWidth: contrast == .increased && highlighted ? 2 : 0))
            .padding(.top, hitTop)
            .padding(.bottom, hitBottom)
            .contentShape(Rectangle())
    }
}

/// Toolbar actions remain unwrapped in every appearance and press state.
/// Colors keep the same IDs as the corresponding material-styled keys.
private struct BareKeyboardToolbarStyle: ButtonStyle {
    @EnvironmentObject private var settings: AzkiSettings
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    let id: String

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 3)
            .frame(minWidth: 44, maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color.primary)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
