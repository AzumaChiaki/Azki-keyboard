// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// The keys a sliding finger crossed. `required` marks those it turned on, which a
/// word must contain, because a finger only changes direction for a letter.
public struct GlideTrace: Equatable, Sendable {
    public let keys: [Character]
    public let required: Set<Int>

    public init(keys: [Character], required: Set<Int>) {
        self.keys = keys
        self.required = required
    }

    private static let spacing: CGFloat = 8
    /// Compares headings this many samples either side, which ignores finger wobble.
    private static let window = 3
    private static let cornerAngle: CGFloat = .pi / 3

    public init?(path: [CGPoint], letters: [(letter: Character, frame: CGRect)]) {
        let points = Self.resampled(path)
        guard !points.isEmpty else { return nil }
        let frames = letters.map(\.frame)
        var keys: [Character] = []
        var indexOfPoint: [Int] = []
        for point in points {
            guard let index = KeyHitMap.nearest(to: point, in: frames) else { return nil }
            if keys.last != letters[index].letter { keys.append(letters[index].letter) }
            indexOfPoint.append(keys.count - 1)
        }
        var required: Set<Int> = [0, keys.count - 1]
        var sample = Self.window
        while sample + Self.window < points.count {
            let before = points[sample - Self.window], here = points[sample], after = points[sample + Self.window]
            let turn = abs(Self.angle(from: before, to: here, then: after))
            if turn > Self.cornerAngle {
                required.insert(indexOfPoint[sample])
                sample += Self.window
            }
            sample += 1
        }
        self.init(keys: keys, required: required)
    }

    private static func angle(from a: CGPoint, to b: CGPoint, then c: CGPoint) -> CGFloat {
        let turn = atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x)
        return atan2(sin(turn), cos(turn))
    }

    private static func resampled(_ path: [CGPoint]) -> [CGPoint] {
        guard var last = path.first else { return [] }
        var points = [last]
        for point in path.dropFirst() where hypot(point.x - last.x, point.y - last.y) >= spacing {
            points.append(point)
            last = point
        }
        if let end = path.last, end != points.last { points.append(end) }
        return points
    }

    /// The furthest key a word may jump to from `key`. A corner is only placed to within
    /// a key, so a word may pass one by as long as it lands right after.
    public func reach(from key: Int) -> Int {
        min((required.filter { $0 > key }.min() ?? keys.count - 1) + 1, keys.count - 1)
    }

    /// Whether `word` can be read off these keys, keeping every required one.
    public func allows(_ word: [Character]) -> Bool {
        guard let first = word.first, first == keys.first, word.last == keys.last else { return false }
        func walk(_ letter: Int, _ key: Int) -> Bool {
            if letter == word.count - 1 { return key == keys.count - 1 }
            // A doubled letter stays on its key.
            if word[letter + 1] == keys[key], walk(letter + 1, key) { return true }
            guard key + 1 < keys.count else { return false }
            return (key + 1...reach(from: key)).contains { word[letter + 1] == keys[$0] && walk(letter + 1, $0) }
        }
        return walk(0, 0)
    }
}
