// SPDX-License-Identifier: MIT
import AVFoundation
import Speech
import SwiftUI

/// Listens for the keyboard, which can't. Recognition must run on the device: this
/// keyboard promises nothing typed leaves it, and that covers what is said.
@MainActor
final class VoiceRecorder: ObservableObject {
    static let scheme = "azkiinput"
    /// The microphone stays on after the user goes back, so it must stop by itself.
    private static let longestSession: TimeInterval = 120
    private static let lastWordsWait: UInt64 = 1_000_000_000

    @Published private(set) var state: VoiceBridge.State?
    private let bridge = VoiceBridge(directory: AzkiSettings.sharedStore().directory)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var ticker: Timer?
    private var started = Date()

    func open(_ url: URL) {
        guard url.scheme == Self.scheme else { return }
        let locale = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "locale" }?.value
        Task { await start(locale: locale ?? "zh-CN") }
    }

    func finish() {
        guard state?.phase == .listening else { return }
        ticker?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        Task {
            try? await Task.sleep(nanoseconds: Self.lastWordsWait)
            complete()
        }
    }

    func dismiss() {
        stop()
        bridge.clear()
        state = nil
    }

    private func start(locale: String) async {
        stop()
        bridge.clear()
        started = Date()
        publish(.listening, "")
        if AzkiQA.enabled {
            publish(.listening, "语音测试")
            return tickWhileListening()
        }
        guard await Self.permitted() else { return fail("请在设置中允许麦克风和语音识别") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return fail("此语言不支持离线识别") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            return fail("无法使用麦克风")
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && text == nil
            Task { @MainActor in self?.heard(text, isFinal: isFinal, failed: failed) }
        }
        tickWhileListening()
    }

    private func heard(_ text: String?, isFinal: Bool, failed: Bool) {
        guard state?.phase == .listening else { return }
        if let text { publish(.listening, text) }
        if isFinal { complete() } else if failed { fail("没有识别到语音") }
    }

    private func tickWhileListening() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        switch bridge.takeCommand() {
        case .finish: finish()
        case .cancel: dismiss()
        case nil:
            if Date().timeIntervalSince(started) > Self.longestSession { finish() }
            else if let state { publish(state.phase, state.text) }
        }
    }

    private func complete() {
        guard state?.phase == .listening else { return }
        let text = state?.text ?? ""
        stop()
        publish(.finished, text)
        state = nil
    }

    private func fail(_ reason: String) {
        stop()
        publish(.failed, reason)
    }

    private func publish(_ phase: VoiceBridge.Phase, _ text: String) {
        let next = VoiceBridge.State(phase: phase, text: text)
        state = next
        bridge.write(next)
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func permitted() async -> Bool {
        let microphone = await withCheckedContinuation { done in
            AVAudioSession.sharedInstance().requestRecordPermission { done.resume(returning: $0) }
        }
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        return microphone && speech == .authorized
    }
}

/// Doesn't cover the app, so a field being typed in keeps its keyboard.
struct VoiceBanner: View {
    @ObservedObject var recorder: VoiceRecorder

    var body: some View {
        if let state = recorder.state {
            HStack(spacing: 12) {
                Image(systemName: state.phase == .failed ? "mic.slash" : "mic.fill")
                Text(state.text.isEmpty ? "正在听…" : state.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("VoiceBannerText")
                if state.phase == .failed {
                    Button("关闭") { recorder.dismiss() }
                } else {
                    Button("完成") { recorder.finish() }.accessibilityIdentifier("VoiceBannerDone")
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}
