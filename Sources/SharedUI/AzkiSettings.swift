// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI

@MainActor
final class AzkiSettings: ObservableObject {
    /// Set per signing identity at build time, because a group belongs to one team.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AzkiAppGroup") as? String
        ?? "group.com.example.AzkiInputMethod"
    @Published private(set) var preferences = AzkiPreferences()
    @Published private(set) var status = "尚未导入自定义词库"
    @Published private(set) var memoryStatus = ""
    @Published private(set) var entryCount = 0
    @Published private(set) var learnedCount = 0
    let store: ProfileStore
    let memoryStore: InputMemoryStore

    static var sharedContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    static func sharedStore() -> ProfileStore {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProfileStore(directory: base.appendingPathComponent("NativeProfile", isDirectory: true))
    }

    init(store: ProfileStore? = nil) {
        let resolved = store ?? Self.sharedStore()
        self.store = resolved
        self.memoryStore = InputMemoryStore(directory: resolved.directory)
        reload()
    }

    func reload() {
        do {
            preferences = try store.loadPreferences()
            entryCount = try store.loadEntries().count
        } catch { status = "读取失败：\(error.localizedDescription)" }
        learnedCount = memoryStore.loadOrEmpty().count
    }

    /// Clearing is explicit and separate from disabling learning: turning the
    /// feature off stops new writes but does not silently erase old entries.
    func clearInputMemory() {
        do {
            try memoryStore.clear()
            learnedCount = 0
            memoryStatus = "已清除本机输入记忆"
        } catch {
            memoryStatus = "清除失败：\(error.localizedDescription)"
        }
    }

    func update(_ edit: (inout AzkiPreferences) -> Void) {
        _ = savePreferences(edit)
    }

    /// Returns success only after the existing atomic store write completes.
    func savePreferences(_ edit: (inout AzkiPreferences) -> Void) -> Bool {
        var next = preferences
        edit(&next)
        do {
            try store.savePreferences(next)
            preferences = next
            return true
        } catch {
            status = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var outcome: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { safeURL in
            outcome = Result {
                let size = try safeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                return try Data(contentsOf: safeURL)
            }
        }
        do {
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw CocoaError(.fileReadUnknown) }
            let report = try store.importTSV(try outcome.get())
            reload()
            status = "导入完成：\(report.count) 条，合并重复 \(report.duplicates) 条"
        } catch { status = "导入失败，原词库未替换：\(error.localizedDescription)" }
    }

    func restorePrevious() {
        do {
            let count = try store.restorePrevious()
            reload()
            status = "已恢复上次词库：\(count) 条"
        } catch { status = "恢复失败：\(error.localizedDescription)" }
    }

    func report(_ message: String) { status = message }
}

extension KeyboardLanguage {
    var displayName: String {
        switch self { case .chinese: return "中文"; case .english: return "English"; case .japanese: return "日本語" }
    }
}

extension AppearanceTheme {
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}
