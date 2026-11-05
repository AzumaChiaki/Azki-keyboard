// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import UIKit

/// A ticket is valid only in one document and one version of the local draft.
struct KeyboardInputTicket: Hashable, Sendable {
    let document: UUID
    let generation: UInt64
    let revision: UInt64
}

struct KeyboardCandidate: Identifiable {
    let id: Int
    let text: String
    let reading: String
    /// What the lexicon and input memory know it as, when `text` is shown in traditional.
    var plain: String? = nil
    var consumed: Int? = nil
    /// The engine source label, used only to decide whether a learned entry is
    /// a user composition or an ordinary dictionary surface.
    var source: String = ""

    var learnedText: String { plain ?? text }
}

/// One fixed layout per device class. Nothing here depends on input state, so
/// keys keep their exact frames while composing, expanding or showing messages.
struct KeyboardMetrics: Equatable {
    // Keys draw smaller than their pitch. The space between them still types,
    // because every touch goes to the closest key.
    var keyHeight: CGFloat = 44
    var rowGap: CGFloat = 12
    var keyGap: CGFloat = 7
    var sideInset: CGFloat = 4
    var candidateHeight: CGFloat = 46
    var letterSize: CGFloat = 24
    var candidateSize: CGFloat = 21
    var functionSize: CGFloat = 17
    var topInset: CGFloat = 4
    var barGap: CGFloat = 4
    var bottomInset: CGFloat = 4
    /// How far the candidates reach into the keys once typing pauses.
    var candidateReach: CGFloat = 6
    /// While typing, fingers aimed at the top row land short of it. They shouldn't pick
    /// a candidate, so the keys claim this much of the bar until typing pauses.
    var typingReach: CGFloat = 10

    static func current(idiom: UIUserInterfaceIdiom, landscape: Bool) -> KeyboardMetrics {
        var metrics = KeyboardMetrics()
        if idiom == .pad {
            metrics.keyHeight = 56
            metrics.rowGap = 10
            metrics.keyGap = 9
            metrics.sideInset = 7
            metrics.candidateHeight = 50
            metrics.letterSize = 26
            metrics.functionSize = 18
            metrics.barGap = 6
            metrics.bottomInset = 6
        } else if landscape {
            metrics.keyHeight = 38
            metrics.rowGap = 8
            metrics.candidateHeight = 38
            metrics.candidateSize = 20
            metrics.letterSize = 22
            metrics.functionSize = 16
            metrics.barGap = 3
            metrics.bottomInset = 3
            // The bar is short here, so it needs the room more than the keys do.
            metrics.candidateReach = 12
            metrics.typingReach = 6
        }
        return metrics
    }

    var gridHeight: CGFloat { keyHeight * 4 + rowGap * 3 }
    var totalHeight: CGFloat { topInset + candidateHeight + barGap + gridHeight + bottomInset }
}

enum KeyboardPanel: Equatable { case keys, languages, quick, addPhrase, candidates, restoreDraft, voice }
enum QuickTab: String, CaseIterable { case clipboard, phrases }
enum PhraseField: Equatable { case text, abbreviation }
enum KeyboardPage: Equatable { case letters, numbers, symbols }

enum KeyboardAction {
    /// `alternatives` are the letters a touch between keys may have meant.
    case type(String, alternatives: [Character] = []), punctuation(String), candidate(KeyboardCandidate)
    case chinese(ChineseScript)
    /// A letter chosen from a held key, which is written as it is rather than decoded.
    case letterVariant(String)
    case glide(GlideTrace)
    case finishVoice
    case backspace, backspaceRepeat(Int), clearAll, space, enter, shift, changePage, globe, dismiss, cancel, savePhrase
    case show(KeyboardPanel), language(KeyboardLanguage)
    case phrase(String, KeyboardInputTicket?)
    case restoreDraft(KeyboardInputTicket?, DraftTransferStore.Lease?)
    case discardDraft(KeyboardInputTicket?, DraftTransferStore.Lease?)
}

/// Changes on every key. Kept apart from the model, so typing redraws the candidates
/// and leaves the keys alone: a redraw of the keys is what a next touch would wait for.
@MainActor
final class CandidateList: ObservableObject {
    @Published var items: [KeyboardCandidate] = []
    @Published var preedit = ""
}

/// Separate from the model, so a sliding finger redraws only the trail.
@MainActor
final class GlideTrail: ObservableObject {
    @Published var points: [CGPoint] = []
}

@MainActor
final class KeyboardModel: ObservableObject {
    let candidateList = CandidateList()
    var candidates: [KeyboardCandidate] {
        get { candidateList.items }
        set { candidateList.items = newValue }
    }
    var preedit: String {
        get { candidateList.preedit }
        set { candidateList.preedit = newValue }
    }
    /// Views only care whether there is a draft, which changes once per word.
    var rawInput = "" {
        didSet { if rawInput.isEmpty == isComposing { isComposing.toggle() } }
    }
    @Published private(set) var isComposing = false
    /// A new one comes with every key, and only the panels use it.
    var ticket: KeyboardInputTicket? {
        willSet { if panel != .keys { objectWillChange.send() } }
    }
    // Set on every key, so a value that stays the same must not redraw anything.
    var panel: KeyboardPanel = .keys {
        willSet { if newValue != panel { objectWillChange.send() } }
    }
    @Published var page: KeyboardPage = .letters
    var uppercase = false {
        willSet { if newValue != uppercase { objectWillChange.send() } }
    }
    @Published var language: KeyboardLanguage = .chinese
    @Published var script = ChineseScript.simplified
    @Published var returnTitle = "换行"
    @Published var returnEnabled = true
    @Published var returnIsAction = false
    @Published var hostColorScheme: ColorScheme = .light
    @Published var needsGlobe = true
    @Published var fullAccess = false
    @Published var quickTab: QuickTab = .clipboard
    @Published var phraseField: PhraseField = .text
    @Published var phraseText = ""
    @Published var phraseAbbreviation = ""
    @Published var metrics = KeyboardMetrics()
    @Published var hasRecoverableDraft = false
    @Published var draftConfirmationTicket: KeyboardInputTicket?
    @Published var draftConfirmationLease: DraftTransferStore.Lease?
    @Published var variantPopup: VariantPopup?
    @Published var voiceText = ""
    @Published var voiceProblem: String?
    let glideTrail = GlideTrail()
    var send: (KeyboardAction) -> Void = { _ in }
    /// Not published: layout sets these, and nothing on screen draws from them.
    var keyHits: [KeyHit] = [] {
        didSet {
            touchKeys = keyHits.map(\.touchKey)
            keysByID = Dictionary(keyHits.map { ($0.id, $0) }) { _, last in last }
        }
    }
    /// Worked out when the keys change, not on every touch.
    private(set) var touchKeys: [TouchKey] = []
    private(set) var keysByID: [String: KeyHit] = [:]
    /// Frames are in the row's content, so scrolling doesn't republish them.
    var candidateHits: [KeyHit] = []
    weak var candidateScroll: UIScrollView?
    var toolbarFrames: [CGRect] = []
    private var pressSignals: [String: KeyPressSignal] = [:]
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var backspaceRepeater: Task<Void, Never>?
    private var backspaceHandled = false

    func sendCandidate(id: Int) {
        if let candidate = candidates.first(where: { $0.id == id }) { send(.candidate(candidate)) }
    }

    /// One signal per key, so a press redraws only that key while typing fast.
    func pressSignal(_ id: String) -> KeyPressSignal {
        if let signal = pressSignals[id] { return signal }
        let signal = KeyPressSignal()
        pressSignals[id] = signal
        return signal
    }

    /// iOS plays this only with Full Access, and silently ignores it otherwise.
    func keyTouched(enabled: Bool) {
        guard enabled else { return }
        haptics.impactOccurred()
        // Getting ready for the next one can wait until this touch has been drawn.
        DispatchQueue.main.async { [haptics] in haptics.prepare() }
    }

    /// Holding deletes after a short delay, then faster, then several characters at a time.
    func backspacePressChanged(_ pressed: Bool) {
        backspaceRepeater?.cancel()
        guard pressed else { return }
        backspaceHandled = false
        backspaceRepeater = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            var deleted = 0
            while !Task.isCancelled, let self {
                self.backspaceHandled = true
                self.send(.backspaceRepeat(deleted < 30 ? 1 : 4))
                deleted += 1
                try? await Task.sleep(nanoseconds: deleted < 10 ? 100_000_000 : 50_000_000)
            }
        }
    }

    func stopBackspaceRepeat() { backspaceRepeater?.cancel() }

    func backspaceTapped() {
        if !backspaceHandled { send(.backspace) }
        backspaceHandled = false
    }

    func backspaceSwiped() {
        backspaceRepeater?.cancel()
        backspaceHandled = true
        send(.clearAll)
    }

    var canSavePhrase: Bool { !phraseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var spaceTitle: String {
        if !rawInput.isEmpty {
            switch language {
            case .chinese: return "选词"
            case .english: return "space"
            case .japanese: return "変換"
            }
        }
        switch language {
        case .chinese: return "空格"
        case .english: return "space"
        case .japanese: return "空白"
        }
    }
}
