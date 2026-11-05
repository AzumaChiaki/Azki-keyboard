// SPDX-License-Identifier: MIT
import CoreGraphics

/// Assigns every touch to the closest key, so a key's target reaches halfway to its
/// neighbours and out to the keyboard's edges, leaving no dead zones.
public enum KeyHitMap {
    public static func nearest(to point: CGPoint, in frames: [CGRect]) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (index, frame) in frames.enumerated() {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// The other keys a touch may have meant, closest first. Only a touch outside every
    /// key is in doubt: one on a key means that key, however close to its edge.
    public static func neighbours(of chosen: Int, at point: CGPoint, in frames: [CGRect], reach: CGFloat) -> [Int] {
        guard !frames.contains(where: { $0.contains(point) }) else { return [] }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return frames.indices.filter { $0 != chosen && distance(frames[$0]) <= reach }
            .sorted { distance(frames[$0]) < distance(frames[$1]) }
    }
}
