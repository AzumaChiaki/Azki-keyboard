// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Original keyboard extension. The draft is shown as host marked text until it is
/// committed or cancelled, and it never enters persistent storage.
@MainActor
final class KeyboardViewController: UIInputViewController {
    private static let draftTransfers = DraftTransferStore()
    private static let draftAvailabilityChanged = Notification.Name("AzkiInputMethod.draftAvailabilityChanged")
    private static var draftExpiryTask: Task<Void, Never>?
    private var draftLease: DraftTransferStore.Lease?
    private var needsDraftActivation = true
    // Nominate an appearance before the first host IPC. An older controller
    // cannot acquire a new lease after a successor appears during reentry.
    private static var currentAppearance: UUID?
    private var appearance: UUID?
    private var ownsAppearance: Bool {
        appearance != nil && appearance == Self.currentAppearance
    }
    private var draftAvailabilityObserver: NSObjectProtocol?
    /// The marked text this controller last wrote into the current document.
    private var hostMarkedText = ""
    private var finishedLeftoverMarkedText = false
    /// The draft that `model.candidates` was looked up for.
    private var candidatesInput = ""
    /// Letters each draft position may have meant, for touches between keys.
    private var keyAlternatives: [Int: [Character]] = [:]

    private struct ShownCandidate: Hashable {
        let language: KeyboardLanguage
        let reading: String
        let text: String
    }

    private struct LearningSession {
        var shown: [ShownCandidate] = []
        var shownKeys = Set<ShownCandidate>()
        /// Tapped pieces inside one composition, used to learn a phrase the
        /// user assembled instead of a single dictionary word.
        var composedText = ""
        var composedReading = ""
        var selections = 0
    }

    private var activeDialectRegionID: String? {
        guard model.language == .chinese, settings.preferences.dialectEnabled else { return nil }
        return settings.preferences.dialectRegionID
    }

    private var hasActiveDraftSession: Bool {
        ownsAppearance && (draftLease.map { Self.draftTransfers.isActive($0) } ?? false)
    }

    private var canReadHost: Bool {
        visible && ownsAppearance && (needsDraftActivation || hasActiveDraftSession)
    }

    private let model = KeyboardModel()
    private let settings = AzkiSettings()
    private let engine = OfflineEngine(databaseURL: Bundle.main.url(forResource: "lexicon", withExtension: "sqlite"))
    private let lookupQueue = DispatchQueue(label: "AzkiInputMethod.lookup", qos: .userInitiated)
    private var customWords: [UserWord] = []
    private lazy var memoryStore = InputMemoryStore(directory: settings.store.directory)
    private var inputMemory = InputMemory.empty
    private lazy var voice = VoiceBridge(directory: settings.store.directory)
    private var voiceFollower: Task<Void, Never>?
    /// Reading and writing the file takes far longer than the gap between two keys.
    private let memoryQueue = DispatchQueue(label: "AzkiInputMethod.memory", qos: .utility)
    /// Candidates seen during the current composition. One exposure per
    /// candidate per composition keeps typing speed from distorting adoption.
    private var learning = LearningSession()
    private var host: UIHostingController<AnyView>?
    private var keyboardHeight: NSLayoutConstraint?
    private var documentID: UUID?
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var visible = false
    private var appeared = false
    private var capabilitiesNeedRefresh = true
    private var lastRequestedLanguage: String?
    private var pasteRequest: UUID?
    private var pasteProgress: Progress?
    private var lookupWork: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    /// Asks the system not to hold back touches near the sides, where q, a, p and l are.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.left, .right] }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Avoid publishing the default Chinese language before the saved choice.
        model.language = settings.preferences.language
        model.script = settings.preferences.chineseScript
        updateAppearance()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (controller: KeyboardViewController, _: UITraitCollection) in
                controller.updateAppearance()
            }
        }
        model.send = { [weak self] action in self?.perform(action) }
        let root = KeyboardRootView(model: model, pasteContext: KeyboardPasteContext(controller: self)).environmentObject(settings)
        let hosting = UIHostingController(rootView: AnyView(root))
        host = hosting
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        let settings = settings
        let container = KeyTouchContainer(model: model) { settings.preferences.keyHaptics }
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        container.addSubview(hosting.view)
        for (inner, outer) in [(container, view!), (hosting.view!, container)] {
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
                inner.topAnchor.constraint(equalTo: outer.topAnchor),
                inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor)
            ])
        }
        hosting.didMove(toParent: self)
        model.metrics = .current(idiom: traitCollection.userInterfaceIdiom, landscape: false)
        let constraint = view.heightAnchor.constraint(equalToConstant: model.metrics.totalHeight)
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        keyboardHeight = constraint
        draftAvailabilityObserver = NotificationCenter.default.addObserver(
            forName: Self.draftAvailabilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDraftAvailability() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.capabilitiesNeedRefresh = true
                self?.reloadProfile()
            }
        }
        reloadMemory()
    }

    /// Memory is optional and local. When learning is disabled the keyboard
    /// does not read or write the file, but keeps it until the user clears it.
    private func reloadMemory() {
        learning = LearningSession()
        guard settings.preferences.learningEnabled else {
            inputMemory = .empty
            return
        }
        let store = memoryStore
        memoryQueue.async { [weak self] in
            let memory = store.loadOrEmpty()
            Task { @MainActor [weak self] in self?.inputMemory = memory }
        }
    }

    /// Nothing is learned where the text is an address, an account or a code.
    private var learnsHere: Bool {
        guard settings.preferences.learningEnabled else { return false }
        let proxy = textDocumentProxy
        if let type = proxy.keyboardType, [.emailAddress, .URL, .webSearch].contains(type) { return false }
        let private_: [UITextContentType] = [.username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL,
                                             .telephoneNumber, .creditCardNumber]
        return !(proxy.textContentType.flatMap { $0 }.map(private_.contains) ?? false)
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let draftAvailabilityObserver { NotificationCenter.default.removeObserver(draftAvailabilityObserver) }
        pasteProgress?.cancel()
        lookupWork?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearance = UUID()
        Self.currentAppearance = appearance
        visible = true
        updateAppearance()
        if needsDraftActivation || !hasActiveDraftSession {
            // A retained hidden model must not paint old content while the first
            // public host query is reentering. The bounded handoff remains hidden.
            clearDraft(preserveStoredDraft: true)
            model.panel = .keys
            model.hasRecoverableDraft = false
        }
        reloadProfile()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        capabilitiesNeedRefresh = true
        reloadProfile()
        resumeVoice()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard visible, let scene = view.window?.windowScene else { return }
        let metrics = KeyboardMetrics.current(idiom: traitCollection.userInterfaceIdiom,
                                              landscape: scene.interfaceOrientation.isLandscape)
        if model.metrics != metrics { model.metrics = metrics }
        if keyboardHeight?.constant != metrics.totalHeight { keyboardHeight?.constant = metrics.totalHeight }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #available(iOS 17.0, *) { return }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateAppearance()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        if model.panel == .addPhrase {
            model.panel = .keys
            closePhraseForm()
        }
        clearHostMarkedText()
        visible = false
        appeared = false
        model.stopBackspaceRepeat()
        // The app keeps listening. This is the keyboard leaving for it, and it picks up on return.
        voiceFollower?.cancel()
        voiceFollower = nil
        if model.panel == .voice { model.panel = .keys }
        flushLearningSession()
        parkCurrentDraft()
        if ownsAppearance { Self.currentAppearance = nil }
        appearance = nil
        revokeDeferredActions()
        super.viewWillDisappear(animated)
        // The handoff stays in process memory. An unverified input target can
        // recover it only after explicit confirmation.
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        // UIKit may be resetting its document here; inspect it only after the change.
        invalidateHostOperations()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard visible else { return }
        synchronizeDocument()
        updateTraits()
        refreshCapabilitiesIfReady()
        refreshCandidates()
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        // UIKit may be resetting its document here; inspect it only after the change.
        invalidateHostOperations()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard visible else { return }
        synchronizeDocument()
        updateTraits()
        refreshCapabilitiesIfReady()
        refreshCandidates()
    }

    private func reloadProfile() {
        guard canReadHost else { return }
        settings.reload()
        customWords = (try? settings.store.loadEntries()) ?? []
        reloadMemory()
        model.script = settings.preferences.chineseScript
        let changedLanguage = model.language != settings.preferences.language
        if changedLanguage {
            clearDraft()
            if let draftLease { Self.draftTransfers.revoke(using: draftLease) }
            draftLease = nil
            needsDraftActivation = true
            model.language = settings.preferences.language
        }
        synchronizeDocument()
        if changedLanguage { discardStoredDraft() }
        updateTraits()
        refreshCapabilitiesIfReady()
        refreshCandidates()
    }

    /// The public Objective-C getter can transiently return nil during UIKit's
    /// document reset, despite its nonnull declaration. Read its object result
    /// before bridging so a missing identifier cannot trap in Swift UUID bridging.
    private func currentDocumentIdentifier() -> UUID? {
        guard canReadHost else { return nil }
        let selector = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard let value = textDocumentProxy.perform(selector)?.takeUnretainedValue() as? NSUUID else { return nil }
        return value as UUID
    }

    @discardableResult
    private func synchronizeDocument() -> Bool {
        guard canReadHost else { return false }
        let expectedAppearance = appearance
        let expectedLease = draftLease
        let expectedGeneration = generation
        let expectedRevision = revision
        let identifier = currentDocumentIdentifier()
        // Host IPC may reenter lifecycle callbacks before returning. Never let
        // an old acquisition overwrite a successor or a newer document epoch.
        guard canReadHost, appearance == expectedAppearance, draftLease == expectedLease,
              generation == expectedGeneration, revision == expectedRevision else { return false }
        let changed = documentID != identifier
        if changed {
            // The proxy already targets the new document, so the old field cannot be
            // unmarked and it keeps the draft as ordinary text. Parking it as well
            // would offer the same text a second time.
            if !hostMarkedText.isEmpty {
                hostMarkedText = ""
                model.rawInput = ""
            }
            if model.panel == .addPhrase { closePhraseForm() }
            parkCurrentDraft()
            documentID = identifier
            capabilitiesNeedRefresh = true
            generation &+= 1
            clearDraft(preserveStoredDraft: true)
            model.panel = .keys
            model.uppercase = false
        }
        // A field that lost focus keeps its marked text, and on return UIKit reports
        // no document until that text is finished, so every key would be dropped.
        if identifier != nil {
            finishedLeftoverMarkedText = false
        } else if hostMarkedText.isEmpty, !finishedLeftoverMarkedText {
            finishedLeftoverMarkedText = true
            textDocumentProxy.unmarkText()
        }
        if let identifier, needsDraftActivation {
            let lease = Self.draftTransfers.activate(.init(document: identifier, language: model.language))
            draftLease = lease
            needsDraftActivation = false
            // A parked draft only returns when the user asks. During a focus change the
            // proxy can still report the old document, so restoring on a match would
            // write the draft into the field that just took focus.
            clearDraft(preserveStoredDraft: true)
        }
        updateTicket()
        refreshDraftAvailability()
        return changed
    }

    private func parkCurrentDraft() {
        if let draftLease {
            if model.rawInput.isEmpty {
                Self.draftTransfers.relinquish(using: draftLease)
            } else {
                Self.draftTransfers.park(model.rawInput, using: draftLease)
            }
        }
        draftLease = nil
        needsDraftActivation = true
        Self.scheduleDraftExpiry()
    }

    private static func scheduleDraftExpiry() {
        draftExpiryTask?.cancel()
        guard let delay = draftTransfers.timeUntilExpiry() else {
            draftExpiryTask = nil
            return
        }
        draftExpiryTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay), clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            draftTransfers.expire()
            NotificationCenter.default.post(name: draftAvailabilityChanged, object: nil)
        }
    }

    private func refreshDraftAvailability() {
        guard visible, ownsAppearance else { return }
        let available = model.rawInput.isEmpty && model.ticket != nil
            && (draftLease.map { Self.draftTransfers.hasPending(using: $0) } ?? false)
        if model.hasRecoverableDraft != available { model.hasRecoverableDraft = available }
    }

    private func discardStoredDraft() {
        if let draftLease { Self.draftTransfers.discardPending(using: draftLease) }
        Self.scheduleDraftExpiry()
        refreshDraftAvailability()
    }

    private func applyRecoveredDraft(_ snapshot: DraftTransferStore.Snapshot,
                                     lease: DraftTransferStore.Lease, document: UUID) {
        guard visible, ownsAppearance, draftLease == lease, Self.draftTransfers.isActive(lease),
              documentID == document, model.rawInput.isEmpty else { return }
        let expectedAppearance = appearance
        let expectedGeneration = generation
        let expectedRevision = revision
        if model.language != snapshot.language {
            model.language = snapshot.language
            settings.update { $0.language = snapshot.language }
            Self.draftTransfers.revoke(using: lease)
            // This synchronous rebind uses only the already validated target.
            // The final public proxy read below must still confirm that target.
            draftLease = Self.draftTransfers.activate(.init(document: document, language: snapshot.language))
            needsDraftActivation = false
        }
        let expectedLease = draftLease
        guard canReadHost, let expectedLease else { return }
        let currentDocument = currentDocumentIdentifier()
        guard canReadHost, appearance == expectedAppearance,
              draftLease == expectedLease, Self.draftTransfers.isActive(expectedLease),
              generation == expectedGeneration, revision == expectedRevision,
              documentID == document, currentDocument == document,
              model.rawInput.isEmpty, model.language == snapshot.language else { return }
        model.rawInput = snapshot.input
        model.panel = .keys
        model.page = .letters
        model.uppercase = false
        model.draftConfirmationTicket = nil
        model.draftConfirmationLease = nil
        // Restores the uncommitted marked text and candidates. A later explicit action commits.
        draftChanged()
    }

    private func updateTicket() {
        let next = hasActiveDraftSession
            ? documentID.map { KeyboardInputTicket(document: $0, generation: generation, revision: revision) }
            : nil
        if model.ticket != next { model.ticket = next }
    }

    private func invalidatePaste() {
        pasteRequest = nil
        pasteProgress?.cancel()
        pasteProgress = nil
    }

    private func invalidateHostOperations() {
        // Keep the local draft through layout/host notifications, but revoke all
        // delayed actions, including a paste gesture begun before a cursor move.
        revision &+= 1
        invalidatePaste()
        lookupWork?.cancel()
        // Hidden views retain only inert presentation state. Revocation above
        // still invalidates every delayed action before the next appearance.
        guard visible, ownsAppearance else { return }
        // A host may echo marked-text updates here, so keep showing the candidates
        // instead of flickering on each key.
        if model.rawInput.isEmpty, !model.candidates.isEmpty { model.candidates = [] }
        if model.ticket != nil { model.ticket = nil }
        model.draftConfirmationTicket = nil
        model.draftConfirmationLease = nil
        if model.panel == .restoreDraft { model.panel = .keys }
    }

    private func revokeDeferredActions() {
        revision &+= 1
        invalidatePaste()
        lookupWork?.cancel()
        // Revoke callbacks immediately, but don't rebuild the hosted SwiftUI
        // subtree while UIKit is detaching it. Appearance republishes a ticket.
        guard visible else { return }
        updateTicket()
    }

    private func clearDraft(preserveStoredDraft: Bool = false, preserveComposition: Bool = false) {
        if !preserveStoredDraft { discardStoredDraft() }
        model.draftConfirmationTicket = nil
        model.draftConfirmationLease = nil
        revision &+= 1
        invalidatePaste()
        lookupWork?.cancel()
        clearHostMarkedText()
        if !model.rawInput.isEmpty { model.rawInput = "" }
        keyAlternatives = [:]
        if !model.preedit.isEmpty { model.preedit = "" }
        if !model.candidates.isEmpty { model.candidates = [] }
        candidatesInput = ""
        if model.panel == .candidates { model.panel = .keys }
        // A cancelled composition teaches nothing. A partial candidate keeps its
        // accumulated phrase for the remaining draft.
        flushLearningExposures()
        if !preserveComposition {
            learning.composedText = ""
            learning.composedReading = ""
            learning.selections = 0
        }
        updateTicket()
        refreshDraftAvailability()
    }

    private func draftChanged() {
        keyAlternatives = keyAlternatives.filter { $0.key < model.rawInput.count }
        discardStoredDraft()
        if model.draftConfirmationTicket != nil {
            model.draftConfirmationTicket = nil
            model.draftConfirmationLease = nil
        }
        revision &+= 1
        invalidatePaste()
        let preedit = engine.preedit(input: model.rawInput, language: model.language)
        if model.preedit != preedit { model.preedit = preedit }
        updateHostMarkedText()
        updateTicket()
        updateTraits()
        model.candidateScroll?.contentOffset.x = 0
        // The last candidates stay up until the new ones replace them, which avoids a
        // blank frame on every key. Looking up here would hold the key's feedback back.
        refreshCandidates()
    }

    private var activePhrases: [QuickPhrase] {
        // Text typed into the add form must not expand existing abbreviations.
        model.panel == .addPhrase ? [] : settings.preferences.phrases
    }

    /// Counts one exposure per learned candidate per composition. Only text
    /// already in memory is tracked, so the keyboard never records words the
    /// user merely saw for the first time.
    private func recordCandidatesShown(_ values: [KeyboardCandidate], language: KeyboardLanguage) {
        guard settings.preferences.learningEnabled, model.panel == .keys || model.panel == .candidates,
              language == model.language else { return }
        for candidate in values.prefix(6) {
            guard let entry = inputMemory.entry(text: candidate.learnedText, reading: candidate.reading,
                                               language: language) else { continue }
            let shown = ShownCandidate(language: language, reading: entry.reading, text: entry.text)
            guard learning.shownKeys.insert(shown).inserted else { continue }
            learning.shown.append(shown)
        }
    }

    /// A memory-injected candidate may be a previously learned dictionary
    /// word; only the stored entry knows whether it was user-created.
    private func isUserCreated(_ candidate: KeyboardCandidate?) -> Bool {
        guard let candidate else { return false }
        if candidate.source == OfflineEngine.memorySource,
           let entry = inputMemory.entry(text: candidate.learnedText, reading: candidate.reading,
                                         language: model.language) {
            return entry.userCreated
        }
        return OfflineEngine.isSelfCreated(source: candidate.source)
    }

    private func applyLearningEvents(_ events: [InputMemoryEvent]) {
        guard !events.isEmpty else { return }
        let store = memoryStore
        memoryQueue.async { [weak self] in
            guard let updated = store.record(events) else { return }
            Task { @MainActor [weak self] in self?.inputMemory = updated }
        }
    }

    /// Learned words shown for this exact input and passed over. One seen on the way
    /// to a longer input wasn't turned down, so it doesn't count against it.
    private func passedOver(for selected: ShownCandidate) -> [InputMemoryEvent] {
        let code = Reading.canonical(selected.reading, language: selected.language)
        return learning.shown.filter { $0 != selected && $0.reading == code }.map {
            InputMemoryEvent.exposure(language: $0.language, reading: $0.reading, text: $0.text)
        }
    }

    private func flushLearningExposures() {
        learning.shown.removeAll()
        learning.shownKeys.removeAll()
    }

    private func flushLearningSession() {
        learning = LearningSession()
    }

    /// Records an adopted candidate. A deep-rank tap is the signal that makes
    /// the same candidate open the bar next time; repeated taps keep its score
    /// high, while later exposures without adoption lower it again.
    private func rememberSelection(_ candidate: KeyboardCandidate, rank: Int, finishes: Bool) {
        guard learnsHere, candidate.source != OfflineEngine.emojiSource else {
            learning = LearningSession()
            return
        }
        let language = model.language
        let selected = ShownCandidate(language: language, reading: candidate.reading, text: candidate.learnedText)
        var events = passedOver(for: selected)
        events.append(.selection(language: language, reading: candidate.reading, text: candidate.learnedText,
                                 rank: rank, userCreated: isUserCreated(candidate)))
        learning.composedText += candidate.learnedText
        learning.composedReading += candidate.reading
        learning.selections += 1
        if finishes {
            if learning.selections > 1 {
                events.append(.composition(language: language, reading: learning.composedReading,
                                           text: learning.composedText, rank: max(1, learning.selections),
                                           userCreated: true))
            }
            learning.composedText = ""
            learning.composedReading = ""
            learning.selections = 0
        }
        learning.shown.removeAll()
        learning.shownKeys.removeAll()
        applyLearningEvents(events)
    }

    /// Records a whole composition committed by space, punctuation or return.
    /// If the user tapped several pieces first, a second phrase entry captures
    /// the assembled surface without recording any surrounding context.
    private func rememberCommit(text: String, candidate: KeyboardCandidate?) {
        guard learnsHere else {
            learning = LearningSession()
            return
        }
        let language = model.language
        let surface = (candidate?.plain ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        // A decoded sentence or pinyin kept as letters says nothing about a word.
        let sentence = candidate?.source == OfflineEngine.sentenceSource && !inputMemory.contains(text: surface, language: language)
        let letters = language == .chinese && surface.allSatisfy(\.isASCII)
        guard !surface.isEmpty, !sentence, !letters else {
            flushLearningSession()
            return
        }
        let reading: String
        if let candidate, !candidate.reading.isEmpty { reading = candidate.reading }
        else { reading = model.rawInput }
        let selected = ShownCandidate(language: language, reading: reading, text: surface)
        var events = passedOver(for: selected)
        events.append(.selection(language: language, reading: reading, text: surface, rank: 0,
                                 userCreated: candidate.map { isUserCreated($0) } ?? true))
        if learning.selections > 0, !learning.composedText.isEmpty {
            events.append(.composition(language: language, reading: learning.composedReading + reading,
                                       text: learning.composedText + surface,
                                       rank: max(1, learning.selections), userCreated: true))
        }
        learning = LearningSession()
        applyLearningEvents(events)
    }

    private func publishCandidates(_ values: [LexiconCandidate], input: String, language: KeyboardLanguage) {
        candidatesInput = input
        model.candidates = values.enumerated().map {
            var text = $0.element.text
            if language == .english, input.first?.isUppercase == true,
               $0.element.source != OfflineEngine.phraseSource {
                text = input.count > 1 && input == input.uppercased()
                    ? text.uppercased() : text.prefix(1).uppercased() + text.dropFirst()
            }
            // What the user wrote themselves stays as they wrote it.
            let plain = text
            if language == .chinese, ![OfflineEngine.phraseSource, "词库"].contains($0.element.source) {
                text = TraditionalConverter.convert(text, to: settings.preferences.chineseScript)
            }
            return KeyboardCandidate(id: $0.offset, text: text, reading: $0.element.reading, plain: plain,
                                     consumed: $0.element.consumed, source: $0.element.source)
        }
        recordCandidatesShown(model.candidates, language: language)
    }

    /// Looks up on the main thread, for when the result is needed before the next frame.
    private func fillCandidatesNow() {
        lookupWork?.cancel()
        guard !model.rawInput.isEmpty else { return }
        let values = engine.candidates(input: model.rawInput, language: model.language, custom: customWords, phrases: activePhrases,
                                       alternatives: keyAlternatives, memory: inputMemory,
                                       dialectRegionID: activeDialectRegionID,
                                       emoji: settings.preferences.emojiSuggestions)
        publishCandidates(values, input: model.rawInput, language: model.language)
    }

    /// Shows the draft underlined at the host's caret. The add form keeps its
    /// draft out of the host, because that text belongs to the form.
    private func updateHostMarkedText() {
        guard model.panel != .addPhrase else { return }
        let text = model.preedit.isEmpty ? model.rawInput : model.preedit
        guard !text.isEmpty else { return clearHostMarkedText() }
        guard text != hostMarkedText else { return }
        hostMarkedText = text
        textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
    }

    private func clearHostMarkedText() {
        guard !hostMarkedText.isEmpty else { return }
        hostMarkedText = ""
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
    }

    private func refreshCandidates() {
        lookupWork?.cancel()
        guard visible, hasActiveDraftSession else { return }
        guard !model.rawInput.isEmpty else {
            if !model.candidates.isEmpty { model.candidates = [] }
            return
        }
        let document = documentID
        let input = model.rawInput
        let language = model.language
        let words = customWords
        let phrases = activePhrases
        let alternatives = keyAlternatives
        let memory = inputMemory
        let dialect = activeDialectRegionID
        let emoji = settings.preferences.emojiSuggestions
        let engine = engine
        let work = DispatchWorkItem { [weak self] in
            let values = engine.candidates(input: input, language: language, custom: words, phrases: phrases,
                                           alternatives: alternatives, memory: memory,
                                           dialectRegionID: dialect, emoji: emoji)
            Task { @MainActor [weak self] in
                guard let self, self.visible, self.documentID == document, self.model.rawInput == input else { return }
                self.publishCandidates(values, input: input, language: language)
            }
        }
        lookupWork = work
        lookupQueue.async(execute: work)
    }

    private func isCurrent(_ ticket: KeyboardInputTicket) -> Bool {
        guard visible else { return false }
        synchronizeDocument()
        return visible && hasActiveDraftSession && ticket == model.ticket && documentID == ticket.document
    }

    /// The best candidate that covers the whole draft.
    private var resolvedDraft: String {
        ensureCandidatesMatchDraft()
        return model.candidates.first { $0.consumed == nil }?.text ?? (model.preedit.isEmpty ? model.rawInput : model.preedit)
    }

    /// Candidates can trail the draft by a frame. Committing must never use old ones.
    private func ensureCandidatesMatchDraft() {
        if candidatesInput != model.rawInput { fillCandidatesNow() }
    }

    /// How much of the draft a candidate stands for. Candidates stay up until newer ones
    /// replace them, so what was tapped may be for fewer letters than have been typed.
    private func lettersCovered(by candidate: KeyboardCandidate) -> Int {
        candidate.consumed ?? (model.rawInput.hasPrefix(candidatesInput) ? candidatesInput.count : model.rawInput.count)
    }

    /// Input left over when a candidate covers only the start of the draft.
    private func remainder(after candidate: KeyboardCandidate) -> String {
        String(model.rawInput.dropFirst(lettersCovered(by: candidate)))
    }

    /// The doubtful touches in what `remainder(after:)` leaves, renumbered from its start.
    private func alternatives(after candidate: KeyboardCandidate) -> [Int: [Character]] {
        let covered = lettersCovered(by: candidate)
        return Dictionary(uniqueKeysWithValues: keyAlternatives.filter { $0.key >= covered }.map { ($0.key - covered, $0.value) })
    }

    private func resumeDraft(_ remainder: String, alternatives: [Int: [Character]] = [:]) {
        guard !remainder.isEmpty else { return }
        model.rawInput = remainder
        keyAlternatives = alternatives
        draftChanged()
    }

    /// Every mutation checks its ticket immediately before touching the proxy.
    /// A partial candidate continues composing, so its learning phrase must
    /// survive the otherwise complete draft reset.
    private func insert(_ text: String, ticket: KeyboardInputTicket,
                        preserveComposition: Bool = false) {
        guard visible, isCurrent(ticket), !text.isEmpty else { return }
        // insertText replaces marked text by itself. An explicit unmarkText here would be
        // applied after any marked text set next, turning the remaining pinyin into text.
        hostMarkedText = ""
        clearDraft(preserveComposition: preserveComposition)
        textDocumentProxy.insertText(text)
        updateTraits()
    }

    private func perform(_ action: KeyboardAction) {
        guard visible else { return }
        synchronizeDocument()
        guard visible, hasActiveDraftSession, let ticket = model.ticket else { return }
        if model.panel == .addPhrase, handlePhraseForm(action) { return }
        switch action {
        case .type(let text, let alternatives):
            guard model.rawInput.count + text.count <= 128 else {
                return
            }
            if model.panel != .addPhrase { model.panel = .keys }
            if !alternatives.isEmpty { keyAlternatives[model.rawInput.count] = alternatives }
            model.rawInput += text
            model.uppercase = false
            draftChanged()
        case .glide(let trace):
            guard let spelling = engine.glideSpellings(trace, language: model.language).first else { return }
            // English words are separate, so the last one is finished first.
            if model.language == .english, !model.rawInput.isEmpty { perform(.space) }
            perform(.type(spelling))
        case .finishVoice:
            voice.send(.finish)
        case .letterVariant(let text):
            model.uppercase = false
            if model.language == .chinese, text == "ü", !model.rawInput.isEmpty {
                perform(.type("v"))
            } else if model.language == .english, text.allSatisfy(\.isASCII) {
                perform(.type(text))
            } else {
                // Letters before it stay letters, so that n then ǐ writes nǐ.
                insert(model.rawInput + text, ticket: ticket)
            }
        case .punctuation(let text):
            if !model.rawInput.isEmpty {
                let draft = resolvedDraft
                let first = model.candidates.first
                rememberCommit(text: draft, candidate: first?.text == draft ? first : nil)
                insert(draft + text, ticket: ticket)
            } else {
                insert(text, ticket: ticket)
            }
        case .candidate(let candidate):
            let rest = remainder(after: candidate)
            let restAlternatives = alternatives(after: candidate)
            rememberSelection(candidate, rank: candidate.id, finishes: rest.isEmpty)
            insert(candidate.text, ticket: ticket, preserveComposition: !rest.isEmpty)
            model.panel = .keys
            resumeDraft(rest, alternatives: restAlternatives)
        case .backspace:
            if !model.rawInput.isEmpty {
                model.rawInput.removeLast()
                if model.rawInput.isEmpty { flushLearningSession() }
                draftChanged()
            } else if isCurrent(ticket) {
                discardStoredDraft()
                invalidatePaste()
                revision &+= 1
                updateTicket()
                textDocumentProxy.deleteBackward()
                updateTraits()
            }
        case .backspaceRepeat(let count):
            if !model.rawInput.isEmpty {
                model.rawInput.removeLast(min(count, model.rawInput.count))
                if model.rawInput.isEmpty { flushLearningSession() }
                draftChanged()
                // Stop at the end of the draft, so a long hold can't reach committed text.
                if model.rawInput.isEmpty { model.stopBackspaceRepeat() }
            } else if isCurrent(ticket), textDocumentProxy.hasText {
                deleteFromHost(count)
            } else {
                model.stopBackspaceRepeat()
            }
        case .clearAll:
            if !model.rawInput.isEmpty {
                clearDraft()
                updateTraits()
            } else if isCurrent(ticket) {
                deleteFromHost(textDocumentProxy.documentContextBeforeInput?.count ?? 0)
            }
        case .space:
            if !model.rawInput.isEmpty { ensureCandidatesMatchDraft() }
            if let first = model.candidates.first, first.consumed != nil, !model.rawInput.isEmpty {
                perform(.candidate(first))
                return
            }
            if model.rawInput.isEmpty {
                insert(" ", ticket: ticket)
            } else {
                let draft = resolvedDraft
                let first = model.candidates.first
                rememberCommit(text: draft, candidate: first?.text == draft ? first : nil)
                insert(draft + (model.language == .english ? " " : ""), ticket: ticket)
            }
        case .enter:
            guard model.returnEnabled else { return }
            // In pinyin, Return confirms the letters as typed and does nothing else.
            if model.language == .chinese, !model.rawInput.isEmpty {
                flushLearningSession()
                insert(model.rawInput, ticket: ticket)
                return
            }
            // A standalone newline lets the host interpret its configured Return action.
            // If committing the draft moved focus, do not send Return into that new field.
            if !resolvedDraft.isEmpty {
                let draft = resolvedDraft
                let first = model.candidates.first
                rememberCommit(text: draft, candidate: first?.text == draft ? first : nil)
                insert(draft, ticket: ticket)
                guard visible else { return }
            }
            guard visible, let returnTicket = model.ticket,
                  returnTicket.document == ticket.document,
                  returnTicket.generation == ticket.generation,
                  currentDocumentIdentifier() == ticket.document else {
                synchronizeDocument()
                return
            }
            insert("\n", ticket: returnTicket)
        case .shift:
            model.uppercase.toggle()
        case .changePage:
            switch model.page {
            case .letters: model.page = .numbers
            case .numbers, .symbols: model.page = .letters
            }
            if model.panel != .addPhrase { model.panel = .keys }
        case .globe:
            clearDraft()
            advanceToNextInputMode()
        case .dismiss:
            invalidatePaste()
            dismissKeyboard()
        case .cancel:
            clearDraft()
            model.panel = .keys
            updateTraits()
        case .show(let panel):
            refreshDraftAvailability()
            if panel == .restoreDraft && (!model.hasRecoverableDraft || !model.rawInput.isEmpty) { return }
            // The app may have changed entries while this keyboard stayed open.
            if panel == .quick { settings.reload() }
            let leavingPhraseForm = model.panel == .addPhrase
            stopVoice()
            model.panel = model.panel == panel ? .keys : panel
            if model.panel == .voice { startVoice() }
            if leavingPhraseForm { closePhraseForm() }
            revokeDeferredActions()
            model.draftConfirmationTicket = model.panel == .restoreDraft ? model.ticket : nil
            model.draftConfirmationLease = model.panel == .restoreDraft ? draftLease : nil
            refreshCandidates()
        case .restoreDraft(let sourceTicket, let sourceLease):
            guard model.panel == .restoreDraft, model.rawInput.isEmpty,
                  let sourceTicket, let sourceLease,
                  isCurrent(sourceTicket), sourceLease == draftLease,
                  Self.draftTransfers.isActive(sourceLease) else { return }
            guard let snapshot = Self.draftTransfers.restoreAfterUserConfirmation(using: sourceLease) else {
                model.panel = .keys
                refreshDraftAvailability()
                return
            }
            applyRecoveredDraft(snapshot, lease: sourceLease, document: sourceTicket.document)
        case .discardDraft(let sourceTicket, let sourceLease):
            guard model.panel == .restoreDraft, model.rawInput.isEmpty,
                  let sourceTicket, let sourceLease,
                  isCurrent(sourceTicket), sourceLease == draftLease,
                  Self.draftTransfers.isActive(sourceLease) else { return }
            discardStoredDraft()
            model.draftConfirmationTicket = nil
            model.draftConfirmationLease = nil
            model.panel = .keys
        case .chinese(let script):
            settings.update { $0.chineseScript = script }
            model.script = script
            perform(.language(.chinese))
        case .language(let language):
            // Language selection explicitly cancels the old local draft; it never inserts it.
            clearDraft()
            model.language = language
            settings.update { $0.language = language }
            if let draftLease { Self.draftTransfers.revoke(using: draftLease) }
            draftLease = nil
            needsDraftActivation = true
            synchronizeDocument()
            model.page = .letters
            model.panel = .keys
            updateTraits()
        case .phrase(let text, let sourceTicket):
            guard let sourceTicket, isCurrent(sourceTicket), model.rawInput.isEmpty else { return }
            insert(text, ticket: sourceTicket)
            model.panel = .keys
        case .savePhrase:
            break
        }
    }

    private func startVoice() {
        model.voiceText = ""
        model.voiceProblem = nil
        guard hasFullAccess else {
            model.voiceProblem = "需要打开“允许完全访问”"
            return
        }
        let locale = switch model.language {
        case .chinese: settings.preferences.chineseScript.speechLocale
        case .english: "en-US"
        case .japanese: "ja-JP"
        }
        voice.clear()
        guard let url = URL(string: "azkiinput://voice?locale=\(locale)"), openContainingApp(url) else {
            model.voiceProblem = "无法打开 Azki输入法"
            return
        }
        followVoice()
    }

    /// A keyboard has no API for this, so it asks the application it is hosted in.
    private func openContainingApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let open = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if current.isKind(of: NSClassFromString("UIApplication") ?? NSNull.self), current.responds(to: open) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(current.method(for: open), to: Open.self)(current, open, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func followVoice() {
        voiceFollower?.cancel()
        let patience = Date().addingTimeInterval(8)
        voiceFollower = Task { [weak self] in
            while !Task.isCancelled, let self, self.voiceStep(patience: patience) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Returns whether there is more to wait for.
    private func voiceStep(patience: Date) -> Bool {
        guard let state = voice.current() else {
            if Date() < patience { return true }
            model.voiceProblem = "Azki输入法没有响应"
            return false
        }
        switch state.phase {
        case .listening:
            model.voiceText = state.text
            return true
        case .failed:
            voice.clear()
            model.voiceProblem = state.text
        case .finished:
            synchronizeDocument()
            // Not ready yet after coming back: the result waits for the next step.
            guard visible, hasActiveDraftSession, let ticket = model.ticket else { return true }
            voice.clear()
            model.panel = .keys
            insert(state.text, ticket: ticket)
        }
        return false
    }

    /// Coming back from the app, whatever was said is waiting.
    private func resumeVoice() {
        guard hasFullAccess, voice.current() != nil else { return }
        model.voiceText = ""
        model.voiceProblem = nil
        model.panel = .voice
        followVoice()
    }

    private func stopVoice() {
        guard voiceFollower != nil else { return }
        voiceFollower?.cancel()
        voiceFollower = nil
        voice.send(.cancel)
    }

    private func deleteFromHost(_ count: Int) {
        discardStoredDraft()
        invalidatePaste()
        revision &+= 1
        updateTicket()
        for _ in 0..<count { textDocumentProxy.deleteBackward() }
        updateTraits()
    }

    /// The add form reuses the real keys and candidates, but its text goes to the
    /// form instead of the host. Returns false for actions that behave as usual.
    private func handlePhraseForm(_ action: KeyboardAction) -> Bool {
        let composing = !model.rawInput.isEmpty
        switch action {
        case .type(let text, _) where model.phraseField == .abbreviation:
            appendToPhraseForm(text)
            model.uppercase = false
        case .letterVariant(let text):
            appendToPhraseForm(model.rawInput + text)
            model.uppercase = false
        case .punctuation(let text):
            appendToPhraseForm((composing ? resolvedDraft : "") + text)
        case .candidate(let candidate):
            let rest = remainder(after: candidate)
            let restAlternatives = alternatives(after: candidate)
            appendToPhraseForm(candidate.text)
            resumeDraft(rest, alternatives: restAlternatives)
        case .backspace where !composing:
            deleteFromPhraseForm(1)
        case .backspaceRepeat(let count) where !composing:
            deleteFromPhraseForm(count)
        case .clearAll where !composing:
            deleteFromPhraseForm(Int.max)
        case .space:
            appendToPhraseForm(composing ? resolvedDraft : " ")
        case .enter:
            if composing {
                appendToPhraseForm(model.language == .chinese ? model.rawInput : resolvedDraft)
            } else if model.phraseField == .text {
                model.phraseField = .abbreviation
            } else {
                savePhrase()
            }
        case .savePhrase:
            savePhrase()
        default:
            return false
        }
        return true
    }

    private func deleteFromPhraseForm(_ count: Int) {
        switch model.phraseField {
        case .text: model.phraseText.removeLast(min(count, model.phraseText.count))
        case .abbreviation: model.phraseAbbreviation.removeLast(min(count, model.phraseAbbreviation.count))
        }
    }

    private func appendToPhraseForm(_ text: String) {
        if !model.rawInput.isEmpty { clearDraft() }
        switch model.phraseField {
        case .text:
            model.phraseText = String((model.phraseText + text).prefix(2000))
        case .abbreviation:
            model.phraseAbbreviation = QuickPhrase.normalizedAbbreviation(model.phraseAbbreviation + text) ?? ""
        }
    }

    private func savePhrase() {
        guard model.canSavePhrase else { return }
        let text = model.phraseText
        let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let abbreviation = QuickPhrase.normalizedAbbreviation(model.phraseAbbreviation)
        // The app may have edited phrases since this keyboard last read them.
        settings.reload()
        guard settings.savePreferences({
            $0.phrases.append(QuickPhrase(title: title, text: text, abbreviation: abbreviation))
        }) else { return }
        model.quickTab = .phrases
        model.panel = .quick
        closePhraseForm()
    }

    private func closePhraseForm() {
        model.phraseText = ""
        model.phraseAbbreviation = ""
        model.phraseField = .text
        if !model.rawInput.isEmpty { clearDraft(preserveStoredDraft: true) }
    }

    /// Capture ownership across public proxy calls that can reenter UIKit.
    private func hostContextValidator() -> () -> Bool {
        let expectedAppearance = appearance
        let expectedLease = draftLease
        let expectedGeneration = generation
        let expectedRevision = revision
        return { [weak self] in
            guard let self else { return false }
            return self.visible && self.hasActiveDraftSession
                && self.appearance == expectedAppearance && self.draftLease == expectedLease
                && self.generation == expectedGeneration && self.revision == expectedRevision
        }
    }

    /// Follows the system keyboard container. The proxy's `keyboardAppearance` is
    /// fixed when the field gains focus, so it goes stale if appearance changes.
    /// This reads the parent controller, not the hosting child with a forced SwiftUI scheme.
    private func updateAppearance() {
        let hostScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // No animation: the system switches its container at once, so a fade would lag behind it.
        if model.hostColorScheme != hostScheme { model.hostColorScheme = hostScheme }
    }

    private func updateTraits() {
        guard visible, hasActiveDraftSession else { return }
        let isValid = hostContextValidator()
        updateAppearance()
        guard isValid() else { return }
        let languageIdentifier: String
        switch model.language {
        case .chinese: languageIdentifier = "zh-Hans"
        case .english: languageIdentifier = "en"
        case .japanese: languageIdentifier = "ja"
        }
        // This setter sends state back to the host. Cache our request rather than
        // comparing a host-normalized/temporarily missing getter and sending it again.
        if lastRequestedLanguage != languageIdentifier {
            lastRequestedLanguage = languageIdentifier
            primaryLanguage = languageIdentifier
            guard isValid() else { return }
        }
        let automaticReturn = textDocumentProxy.enablesReturnKeyAutomatically == true
        guard isValid() else { return }
        let returnEnabled = !automaticReturn || textDocumentProxy.hasText || !model.rawInput.isEmpty
        guard isValid() else { return }
        let kind = textDocumentProxy.returnKeyType ?? .default
        guard isValid() else { return }
        if model.returnEnabled != returnEnabled { model.returnEnabled = returnEnabled }
        let returnIsAction = kind != .default
        if model.returnIsAction != returnIsAction { model.returnIsAction = returnIsAction }
        let names: (String, String, String)
        switch kind {
        case .go: names = ("前往", "go", "開く")
        case .google, .yahoo, .search: names = ("搜索", "search", "検索")
        case .join: names = ("加入", "join", "参加")
        case .next: names = ("下一项", "next", "次へ")
        case .route: names = ("路线", "route", "経路")
        case .send: names = ("发送", "send", "送信")
        case .done: names = ("完成", "done", "完了")
        case .emergencyCall: names = ("紧急呼叫", "call", "緊急電話")
        case .continue: names = ("继续", "continue", "続ける")
        default: names = ("换行", "return", "改行")
        }
        let returnTitle: String
        switch model.language {
        case .chinese: returnTitle = names.0
        case .english: returnTitle = names.1
        case .japanese: returnTitle = names.2
        }
        if model.returnTitle != returnTitle { model.returnTitle = returnTitle }
    }

    private func refreshCapabilitiesIfReady() {
        guard capabilitiesNeedRefresh, visible, appeared, documentID != nil, hasActiveDraftSession else { return }
        // These queries can perform IPC. They are not part of each text-change callback.
        capabilitiesNeedRefresh = false
        let isValid = hostContextValidator()
        let needsGlobe = needsInputModeSwitchKey
        guard isValid() else { return }
        let fullAccess = hasFullAccess
        guard isValid() else { return }
        if model.needsGlobe != needsGlobe { model.needsGlobe = needsGlobe }
        if model.fullAccess != fullAccess { model.fullAccess = fullAccess }
    }

    /// Called only by an immutable, context-bound UIPasteControl target after a user gesture.
    func receivePaste(_ providers: [NSItemProvider], ticket: KeyboardInputTicket) {
        guard visible, hasFullAccess, model.panel == .quick, model.quickTab == .clipboard, isCurrent(ticket), model.rawInput.isEmpty else { return }
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
              provider.canLoadObject(ofClass: NSString.self) else {
            return
        }
        invalidatePaste()
        let request = UUID()
        pasteRequest = request
        pasteProgress = provider.loadObject(ofClass: NSString.self) { [weak self] item, error in
            let value = item as? String
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.visible, self.pasteRequest == request,
                      self.isCurrent(ticket), self.model.rawInput.isEmpty else { return }
                self.pasteRequest = nil
                self.pasteProgress = nil
                guard !failed, let value else {
                    return
                }
                guard value.utf8.count <= 65_536 else {
                    return
                }
                self.insert(value, ticket: ticket)
                self.model.panel = .keys
            }
        }
    }
}
