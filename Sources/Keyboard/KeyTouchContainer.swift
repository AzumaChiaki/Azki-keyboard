// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit

/// One key's touch target. Closures are excluded from equality: they read current
/// model state when called, so only a change in what is shown needs republishing.
struct KeyHit: Equatable {
    let id: String
    let frame: CGRect
    let title: String
    let enabled: Bool
    let action: () -> Void
    var onPressChange: ((Bool) -> Void)?
    var onSwipeLeft: (() -> Void)?
    /// Replaces `action` for a touch between keys, given the letters it may have meant.
    var onGapTouch: (([Character]) -> Void)?
    /// What holding the key offers. Choosing one calls `onVariant`.
    var variants: [String] = []
    var onVariant: ((String) -> Void)?
    var flick: String?
    var onFlick: ((String) -> Void)?
    var glides = false
    var typesText = false

    static func == (first: KeyHit, second: KeyHit) -> Bool {
        first.id == second.id && first.frame == second.frame && first.title == second.title
            && first.enabled == second.enabled && first.variants == second.variants
            && first.flick == second.flick && first.glides == second.glides
    }

    var touchKey: TouchKey {
        TouchKey(id: id, frame: frame, enabled: enabled, waitsForRelease: onPressChange != nil,
                 swipesLeft: onSwipeLeft != nil, typesText: typesText, isLetter: onGapTouch != nil,
                 variants: variants, flick: flick, glides: glides)
    }
}

struct KeyHitsPreference: PreferenceKey {
    static let defaultValue: [KeyHit] = []
    static func reduce(value: inout [KeyHit], nextValue: () -> [KeyHit]) { value += nextValue() }
}

struct ToolbarFramesPreference: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

struct CandidateHitsPreference: PreferenceKey {
    static let defaultValue: [KeyHit] = []
    static func reduce(value: inout [KeyHit], nextValue: () -> [KeyHit]) { value += nextValue() }
}

/// Handles all typing like the system keyboard, instead of leaving it to each key's
/// `Button`. `KeyTouchTracker` decides what the fingers typed, and this feeds it touches
/// and carries out the result. The candidate row scrolls natively, with touches going to
/// the scroll view itself: a tap recognizer picks the closest candidate, because `Button`
/// inside a scroll view loses the tap to the smallest movement.
/// The buttons remain underneath for VoiceOver and for drawing.
@MainActor
final class KeyTouchContainer: UIView {
    private static let holdDuration: UInt64 = 350_000_000
    private static let typingPause: CFTimeInterval = 0.25
    private let model: KeyboardModel
    private let haptics: () -> Bool
    private var tracker = KeyTouchTracker()
    /// The keys as they were when last touched, which is what a touch still down means.
    private var liveKeys: [String: KeyHit] = [:]
    /// Touch objects are reused, so a late hold timer must not match a newer touch.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private var lastKeyDown: CFTimeInterval = 0
    private lazy var rowTap = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
    /// A touch that stops a moving row is only stopping it.
    private var touchStoppedRow = false

    init(model: KeyboardModel, haptics: @escaping () -> Bool) {
        self.model = model
        self.haptics = haptics
        super.init(frame: .zero)
        // Not .clear: iOS doesn't deliver touches on fully transparent points of a keyboard
        // extension, which would leave the gaps between keys dead whatever hitTest says.
        backgroundColor = UIColor(white: 0.5, alpha: 0.01)
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created in code") }

    private var typingNow: Bool {
        !tracker.isIdle || CACurrentMediaTime() - lastKeyDown < Self.typingPause
    }

    private func isOnKeys(_ point: CGPoint) -> Bool {
        guard let top = model.keyHits.map(\.frame.minY).min() else { return false }
        let reach = typingNow ? model.metrics.typingReach : visibleRow == nil ? 0 : -model.metrics.candidateReach
        return point.y >= top - reach
    }

    /// Takes touches on the key area itself, ahead of the buttons it contains, so they
    /// stay in the accessibility tree. The gap above the keys belongs to the candidates.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard event?.type == .touches, self.point(inside: point, with: event) else { return super.hitTest(point, with: event) }
        if isOnKeys(point) { return self }
        if let row = visibleRow, (row.convert(row.bounds, to: self).minX...row.convert(row.bounds, to: self).maxX).contains(point.x) {
            if rowTap.view !== row { row.addGestureRecognizer(rowTap) }
            touchStoppedRow = row.isDragging || row.isDecelerating
            return row
        }
        // With no candidates, the empty part of the bar is more keyboard.
        if model.panel == .keys, visibleRow == nil, !model.keyHits.isEmpty,
           !model.toolbarFrames.contains(where: { $0.contains(point) }) { return self }
        return super.hitTest(point, with: event)
    }

    private var visibleRow: UIScrollView? {
        model.candidateScroll.flatMap { $0.window == nil ? nil : $0 }
    }

    @objc private func rowTapped() {
        guard !touchStoppedRow, let row = visibleRow else { return }
        // Keys still down were typed first.
        apply(tracker.flush())
        let hits = model.candidateHits
        let point = rowTap.location(in: row)
        guard let index = KeyHitMap.nearest(to: CGPoint(x: point.x, y: hits.first?.frame.midY ?? 0), in: hits.map(\.frame)) else { return }
        model.keyTouched(enabled: haptics())
        hits[index].action()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            // Merged, because a key that left the layout may still be under a finger.
            liveKeys.merge(model.keysByID) { _, latest in latest }
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            lastKeyDown = CACurrentMediaTime()
            apply(tracker.began(id, at: touch.location(in: self), keys: model.touchKeys, bounds: bounds,
                                gapReach: max(model.metrics.keyGap, model.metrics.rowGap) + 2))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.holdDuration)
                guard let self else { return }
                self.apply(self.tracker.holdElapsed(id, bounds: self.bounds))
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            // Every sample since the last frame, because a slide's corners are quick.
            for sample in event?.coalescedTouches(for: touch) ?? [touch] { apply(tracker.moved(id, to: sample.location(in: self))) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        apply(tracker.ended(lifted(touches)))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        apply(tracker.cancelled(lifted(touches)))
    }

    private func lifted(_ touches: Set<UITouch>) -> [(id: Int, point: CGPoint)] {
        touches.compactMap { touch in
            touchIDs.removeValue(forKey: ObjectIdentifier(touch)).map { ($0, touch.location(in: self)) }
        }
    }

    private func apply(_ effects: [TouchEffect]) {
        for effect in effects {
            switch effect {
            case .pressed(let id):
                model.keyTouched(enabled: haptics())
                model.pressSignal(id).pressed = true
                liveKeys[id]?.onPressChange?(true)
            case .released(let id):
                model.pressSignal(id).pressed = false
                liveKeys[id]?.onPressChange?(false)
            case .commit(let id, let alternatives):
                if !alternatives.isEmpty, let onGapTouch = liveKeys[id]?.onGapTouch {
                    onGapTouch(alternatives.compactMap(\.first))
                } else {
                    liveKeys[id]?.action()
                }
            case .commitVariant(let id, let index):
                if let key = liveKeys[id], key.variants.indices.contains(index) { key.onVariant?(key.variants[index]) }
            case .commitFlick(let id):
                if let key = liveKeys[id], let flick = key.flick { key.onFlick?(flick) }
            case .glide(let trace):
                model.send(.glide(trace))
            case .glideMoved(let path):
                model.glideTrail.points = path ?? []
            case .swipedLeft(let id):
                liveKeys[id]?.onSwipeLeft?()
            case .variantsChanged(let popup):
                if model.variantPopup == nil, popup != nil { model.keyTouched(enabled: haptics()) }
                model.variantPopup = popup
            }
        }
    }
}

/// Tells the model which scroll view holds the candidate row.
struct CandidateRowProbe: UIViewRepresentable {
    let model: KeyboardModel

    final class Probe: UIView {
        weak var model: KeyboardModel?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { model?.candidateScroll = scroll; return }
                ancestor = view.superview
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ view: Probe, context: Context) {}
}
