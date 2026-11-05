// SPDX-License-Identifier: MIT
import CoreGraphics

/// What the tracker needs to know about one key.
public struct TouchKey: Equatable {
    public let id: String
    public let frame: CGRect
    public var enabled: Bool
    /// Acts on release only, like a backspace that repeats while held.
    public var waitsForRelease: Bool
    public var swipesLeft: Bool
    /// Harmless to type if the system cancels the touch, unlike Return.
    public var typesText: Bool
    /// Letters can stand in for each other when a touch lands between them.
    public var isLetter: Bool
    public var variants: [String]
    /// The variant chosen when the finger doesn't slide.
    public var defaultVariant: Int
    /// What flicking up types.
    public var flick: String?
    /// A slide starting here can spell a word.
    public var glides: Bool

    public init(id: String, frame: CGRect, enabled: Bool = true, waitsForRelease: Bool = false,
                swipesLeft: Bool = false, typesText: Bool = false, isLetter: Bool = false,
                variants: [String] = [], defaultVariant: Int = 0, flick: String? = nil, glides: Bool = false) {
        self.id = id; self.frame = frame; self.enabled = enabled; self.waitsForRelease = waitsForRelease
        self.swipesLeft = swipesLeft; self.typesText = typesText; self.isLetter = isLetter
        self.variants = variants; self.defaultVariant = defaultVariant; self.flick = flick; self.glides = glides
    }
}

/// The row of variants shown above a held key.
public struct VariantPopup: Equatable {
    public let keyID: String
    public let items: [String]
    public let cells: [CGRect]
    /// Nil once the finger has left, so that lifting it types nothing.
    public var selected: Int?

    private static let cellWidth: CGFloat = 38
    private static let margin: CGFloat = 4
    private static let lift: CGFloat = 6

    /// Puts the default variant over the key, kept inside the keyboard.
    public static func cells(over key: CGRect, count: Int, defaultVariant: Int, in bounds: CGRect) -> [CGRect] {
        let width = min(cellWidth, (bounds.width - margin * 2) / CGFloat(max(count, 1)))
        let wanted = key.midX - width * (CGFloat(defaultVariant) + 0.5)
        let x = max(bounds.minX + margin, min(wanted, bounds.maxX - margin - width * CGFloat(count)))
        let y = max(bounds.minY + 2, key.minY - key.height - lift)
        return (0..<count).map { CGRect(x: x + CGFloat($0) * width, y: y, width: width, height: key.height) }
    }

    fileprivate func cell(atX x: CGFloat) -> Int {
        guard let first = cells.first, first.width > 0 else { return 0 }
        return max(0, min(cells.count - 1, Int((x - first.minX) / first.width)))
    }
}

public enum TouchEffect: Equatable {
    case pressed(String), released(String)
    /// `alternatives` are the letters a touch between keys may have meant.
    case commit(String, alternatives: [String])
    case commitVariant(String, Int)
    case commitFlick(String)
    case glide(GlideTrace)
    /// The path to draw under a sliding finger, or nil to stop drawing it.
    case glideMoved([CGPoint]?)
    case swipedLeft(String)
    case variantsChanged(VariantPopup?)
}

/// Decides what every finger on the keyboard typed. A key is chosen where the finger
/// lands and survives drifting, and a new touch commits the ones still down, so
/// overlapping taps stay in typing order. It knows nothing of UIKit, which is what
/// lets tests cover multi-touch sequences that XCTest cannot perform on a keyboard.
public struct KeyTouchTracker {
    private struct Entry {
        let id: Int
        let key: TouchKey
        let start: CGPoint
        let alternatives: [String]
        var last: CGPoint
        var committed = false
        var popup: VariantPopup?
        var holdPoint = CGPoint.zero
        var sliding = false
        var path: [CGPoint] = []
        var travelled: CGFloat = 0
        var crossed: Set<String> = []
        var gliding = false
    }

    private static let swipeDistance: CGFloat = 24
    private static let flickDistance: CGFloat = 24
    /// Well beyond a drift onto the next key, and beyond a flick up one row.
    private static let glideWidths: CGFloat = 2.2
    private static let glideKeys = 3
    /// A finger that travelled this far was doing something other than tapping.
    private static let cancelledTapDistance: CGFloat = 20
    /// Wobble that shouldn't move the selection away from the default variant.
    private static let slideThreshold: CGFloat = 6

    /// Oldest first, because a rollover must commit in typing order.
    private var entries: [Entry] = []
    private var letters: [TouchKey] = []

    public init() {}

    public var isIdle: Bool { entries.isEmpty }

    /// `gapReach` is how far a key may be from a touch in a gap and still be what was meant.
    public mutating func began(_ id: Int, at point: CGPoint, keys: [TouchKey], bounds: CGRect, gapReach: CGFloat) -> [TouchEffect] {
        var effects = flush()
        let frames = keys.map(\.frame)
        guard let index = KeyHitMap.nearest(to: point, in: frames) else { return effects }
        let key = keys[index]
        let alternatives = key.isLetter
            ? KeyHitMap.neighbours(of: index, at: point, in: frames, reach: gapReach).filter { keys[$0].isLetter }.map { keys[$0].id }
            : []
        if key.glides { letters = keys.filter(\.isLetter) }
        entries.append(Entry(id: id, key: key, start: point, alternatives: alternatives, last: point, path: [point], crossed: [key.id]))
        if key.enabled { effects.append(.pressed(key.id)) }
        return effects
    }

    /// Commits every touch still down, for when something newer needs to go after them.
    public mutating func flush() -> [TouchEffect] {
        var effects: [TouchEffect] = []
        for index in entries.indices {
            let entry = entries[index]
            guard entry.key.enabled, !entry.committed, !entry.key.waitsForRelease else { continue }
            entries[index].committed = true
            if entry.gliding {
                effects += finishGlide(entry)
            } else if let popup = entry.popup {
                entries[index].popup = nil
                effects.append(.variantsChanged(nil))
                if let selected = popup.selected { effects.append(.commitVariant(entry.key.id, selected)) }
            } else {
                effects.append(.commit(entry.key.id, alternatives: entry.alternatives))
            }
        }
        return effects
    }

    public mutating func holdElapsed(_ id: Int, bounds: CGRect) -> [TouchEffect] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return [] }
        let entry = entries[index]
        guard entry.key.enabled, !entry.committed, entry.popup == nil, !entry.key.variants.isEmpty, !flicked(entry),
              !entry.gliding, entry.key.frame.insetBy(dx: -8, dy: -8).contains(entry.last) else { return [] }
        let popup = VariantPopup(keyID: entry.key.id, items: entry.key.variants,
                                 cells: VariantPopup.cells(over: entry.key.frame, count: entry.key.variants.count,
                                                           defaultVariant: entry.key.defaultVariant, in: bounds),
                                 selected: entry.key.defaultVariant)
        entries[index].popup = popup
        entries[index].holdPoint = entry.last
        return [.variantsChanged(popup)]
    }

    public mutating func moved(_ id: Int, to point: CGPoint) -> [TouchEffect] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return [] }
        let previous = entries[index].last
        entries[index].last = point
        if entries[index].popup == nil { return glide(index, from: previous, to: point) }
        let entry = entries[index]
        guard var popup = entry.popup else { return [] }
        if !entry.sliding, abs(point.x - entry.holdPoint.x) < Self.slideThreshold,
           abs(point.y - entry.holdPoint.y) < Self.slideThreshold { return [] }
        entries[index].sliding = true
        let left = point.y > entry.key.frame.maxY + entry.key.frame.height
        let selected = left ? nil : popup.cell(atX: point.x)
        guard selected != popup.selected else { return [] }
        popup.selected = selected
        entries[index].popup = popup
        return [.variantsChanged(popup)]
    }

    /// Only one finger can spell, so a second touch means this is typing after all.
    private mutating func glide(_ index: Int, from previous: CGPoint, to point: CGPoint) -> [TouchEffect] {
        guard entries[index].key.glides, !entries[index].committed, entries.count == 1 else { return [] }
        entries[index].path.append(point)
        entries[index].travelled += hypot(point.x - previous.x, point.y - previous.y)
        if let key = KeyHitMap.nearest(to: point, in: letters.map(\.frame)) { entries[index].crossed.insert(letters[key].id) }
        let entry = entries[index]
        if !entry.gliding {
            guard entry.travelled >= entry.key.frame.width * Self.glideWidths, entry.crossed.count >= Self.glideKeys else { return [] }
            entries[index].gliding = true
        }
        return [.glideMoved(entry.path)]
    }

    private func finishGlide(_ entry: Entry) -> [TouchEffect] {
        let keys = letters.compactMap { key in key.id.first.map { (letter: $0, frame: key.frame) } }
        return [.glideMoved(nil)] + (GlideTrace(path: entry.path, letters: keys).map { [.glide($0)] } ?? [])
    }

    /// Takes every touch lifted in one event, which UIKit reports in no particular order.
    public mutating func ended(_ touches: [(id: Int, point: CGPoint)]) -> [TouchEffect] {
        var effects: [TouchEffect] = []
        for entry in entries where touches.contains(where: { $0.id == entry.id }) {
            let point = touches.first { $0.id == entry.id }?.point ?? entry.last
            var finished = entry
            finished.last = point
            effects += finish(finished)
        }
        entries.removeAll { entry in touches.contains { $0.id == entry.id } }
        return effects
    }

    /// The system cancels touches for its own gestures, and on a keyboard that mustn't
    /// lose a keystroke the finger already made. Only a tap-sized touch counts.
    public mutating func cancelled(_ touches: [(id: Int, point: CGPoint)]) -> [TouchEffect] {
        var effects: [TouchEffect] = []
        for entry in entries where touches.contains(where: { $0.id == entry.id }) {
            guard entry.key.enabled else { continue }
            effects.append(.released(entry.key.id))
            if entry.gliding { effects.append(.glideMoved(nil)) }
            if entry.popup != nil || entry.gliding {
                effects.append(.variantsChanged(nil))
                continue
            }
            let point = touches.first { $0.id == entry.id }?.point ?? entry.last
            let travelled = hypot(point.x - entry.start.x, point.y - entry.start.y)
            if entry.key.typesText, !entry.committed, travelled < Self.cancelledTapDistance {
                effects.append(.commit(entry.key.id, alternatives: entry.alternatives))
            }
        }
        entries.removeAll { entry in touches.contains { $0.id == entry.id } }
        return effects
    }

    private func flicked(_ entry: Entry) -> Bool {
        entry.key.flick != nil && entry.start.y - entry.last.y > Self.flickDistance
    }

    private func finish(_ entry: Entry) -> [TouchEffect] {
        guard entry.key.enabled else { return [] }
        var effects: [TouchEffect] = [.released(entry.key.id)]
        if entry.committed, entry.gliding {
            return effects
        } else if entry.gliding {
            effects += finishGlide(entry)
        } else if let popup = entry.popup {
            effects.append(.variantsChanged(nil))
            if let selected = popup.selected { effects.append(.commitVariant(entry.key.id, selected)) }
        } else if entry.key.swipesLeft, entry.last.x - entry.start.x < -Self.swipeDistance {
            effects.append(.swipedLeft(entry.key.id))
        } else if entry.committed {
            return effects
        } else if flicked(entry) {
            effects.append(.commitFlick(entry.key.id))
        } else {
            effects.append(.commit(entry.key.id, alternatives: entry.alternatives))
        }
        return effects
    }
}
