// SPDX-License-Identifier: MIT
import Foundation

/// iOS gives a keyboard no microphone, so the app listens and the keyboard follows along.
/// Each side writes its own file, so neither overwrites the other.
public struct VoiceBridge: Sendable {
    public enum Phase: String, Codable, Sendable { case listening, finished, failed }
    public enum Command: String, Sendable { case finish, cancel }

    public struct State: Codable, Equatable, Sendable {
        public var phase: Phase
        /// What was heard so far, or why listening failed.
        public var text: String
        public var updated: Date

        public init(phase: Phase, text: String, updated: Date = Date()) {
            self.phase = phase
            self.text = text
            self.updated = updated
        }
    }

    /// The app refreshes `updated` while it listens, so silence means it has gone.
    public static let listeningLifetime: TimeInterval = 3
    /// What was said is meant for the field it was said for, so it doesn't wait long.
    public static let resultLifetime: TimeInterval = 60

    private let stateFile: URL
    private let commandFile: URL

    public init(directory: URL) {
        stateFile = directory.appendingPathComponent("voice-state.json")
        commandFile = directory.appendingPathComponent("voice-command")
    }

    public func write(_ state: State) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    /// The state, unless it is too old to mean anything, in which case it is removed.
    public func current(now: Date = Date()) -> State? {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        let lifetime = state.phase == .listening ? Self.listeningLifetime : Self.resultLifetime
        guard now.timeIntervalSince(state.updated) < lifetime else {
            clear()
            return nil
        }
        return state
    }

    public func send(_ command: Command) {
        try? Data(command.rawValue.utf8).write(to: commandFile, options: .atomic)
    }

    public func takeCommand() -> Command? {
        guard let data = try? Data(contentsOf: commandFile) else { return nil }
        try? FileManager.default.removeItem(at: commandFile)
        return Command(rawValue: String(decoding: data, as: UTF8.self))
    }

    public func clear() {
        try? FileManager.default.removeItem(at: stateFile)
        try? FileManager.default.removeItem(at: commandFile)
    }
}
