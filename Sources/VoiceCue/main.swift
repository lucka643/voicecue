import ApplicationServices
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit
import Speech

final class TerminalUI {
    private let violet = "\u{001B}[38;5;141m"
    private let muted = "\u{001B}[38;5;244m"
    private let reset = "\u{001B}[0m"
    private var status = "Starting up…"
    private var heard = "—"
    private var microphoneLevel = 0.0
    private var turnState = "Listening for your voice"
    private var conversation = [ConversationEntry]()
    private var animationFrame = 0
    private var animationTimer: Timer?
    private var conversationRedrawPending = false
    private var lastConversationRedraw = Date.distantPast

    private enum Speaker {
        case you
        case codex
    }

    private struct ConversationEntry {
        let id: UUID
        let speaker: Speaker
        var text: String
        var isLive: Bool
    }

    func start() {
        redraw()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.animationFrame += 1
            self?.renderPulse()
        }
    }

    func render(status: String) {
        self.status = status
        redrawLiveArea()
    }

    func renderHeard(_ words: String) {
        heard = words.isEmpty ? "—" : words
        redrawLiveArea()
    }

    func renderMicrophone(level: Double) {
        microphoneLevel = min(max(level, 0), 1)
        renderPulse()
    }

    func renderSpokenPrompt(_ prompt: String) {
        guard !prompt.isEmpty else { return }
        if let index = conversation.lastIndex(where: { $0.speaker == .you && $0.isLive }) {
            conversation[index].text = String(prompt.prefix(1_200))
        } else {
            appendConversation(speaker: .you, text: prompt, isLive: true)
            return
        }
        scheduleConversationRedraw()
    }

    func renderTurn(_ state: String) {
        guard state != turnState else { return }
        turnState = state
        switch state {
        case "Codex is thinking", "Codex is speaking":
            if let index = conversation.lastIndex(where: { $0.speaker == .codex && $0.isLive }) {
                conversation[index].text = state
            } else {
                for index in conversation.indices where conversation[index].speaker == .you {
                    conversation[index].isLive = false
                }
                appendConversation(speaker: .codex, text: state, isLive: true)
            }
            scheduleConversationRedraw()
        default:
            if let index = conversation.lastIndex(where: { $0.speaker == .codex && $0.isLive }) {
                conversation[index].isLive = false
                scheduleConversationRedraw()
            }
        }
    }

    func renderCodexSpeech(_ transcript: String) {
        let boundedTranscript = String(transcript.prefix(1_200))
        guard !boundedTranscript.isEmpty else { return }
        if let index = conversation.lastIndex(where: { $0.speaker == .codex && $0.isLive }) {
            conversation[index].text = boundedTranscript
        } else {
            appendConversation(speaker: .codex, text: boundedTranscript, isLive: true)
            return
        }
        scheduleConversationRedraw()
    }

    private func terminalSize() -> (width: Int, height: Int) {
        var windowSize = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize)
        return (windowSize.ws_col > 0 ? Int(windowSize.ws_col) : 72,
                windowSize.ws_row > 0 ? Int(windowSize.ws_row) : 22)
    }

    private func writeRow(_ row: Int, _ text: String, color: String = "") {
        let width = terminalSize().width
        let safeText = String(text.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
        })
        let clipped = String(safeText.prefix(width))
        print("\u{001B}[\(row);1H\(color)\(clipped)\(reset)\u{001B}[K", terminator: "")
        fflush(stdout)
    }

    private func redraw() {
        let size = terminalSize()
        let divider = String(repeating: "─", count: max(1, size.width))
        print("\u{001B}[?25l\u{001B}[2J\u{001B}[H", terminator: "")
        writeRow(2, "  ◜◝   VoiceCue", color: violet)
        writeRow(3, "        local wake phrase shortcut", color: muted)
        redrawConversation()
        writeRow(size.height - 4, divider, color: muted)
        writeRow(size.height - 1, "  Control-C to stop", color: muted)
        redrawLiveArea()
        renderPulse()
    }

    private func redrawLiveArea() {
        let height = terminalSize().height
        writeRow(height - 3, "  \(status)  · Heard: \(heard)", color: muted)
    }

    private func appendConversation(speaker: Speaker, text: String, isLive: Bool = false) {
        let boundedText = String(text.prefix(1_200))
        conversation.append(ConversationEntry(id: UUID(), speaker: speaker, text: boundedText, isLive: isLive))
        if conversation.count > 160 {
            conversation.removeFirst(conversation.count - 160)
        }
        scheduleConversationRedraw()
    }

    private func scheduleConversationRedraw() {
        guard !conversationRedrawPending else { return }
        conversationRedrawPending = true
        let delay = max(0, 0.25 - Date().timeIntervalSince(lastConversationRedraw))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.conversationRedrawPending = false
            self.redrawConversation()
        }
    }

    private func redrawConversation() {
        lastConversationRedraw = Date()
        let size = terminalSize()
        let firstRow = 5
        let lastRow = max(firstRow, size.height - 6)
        guard firstRow <= lastRow else { return }

        for row in firstRow...lastRow {
            writeRow(row, "")
        }

        let lineWidth = max(18, size.width - 6)
        let lines = conversation.flatMap { entry in
            wrappedLines(for: entry, width: lineWidth)
        }
        let visibleLines = lines.suffix(lastRow - firstRow + 1)
        for (offset, line) in visibleLines.enumerated() {
            writeRow(firstRow + offset, line.text, color: line.color)
        }
    }

    private func wrappedLines(for entry: ConversationEntry, width: Int) -> [(text: String, color: String)] {
        let marker = entry.speaker == .you ? "›" : "•"
        let color = entry.speaker == .you ? reset : muted
        let words = entry.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return [] }
        var result = [(text: String, color: String)]()
        var line = "  \(marker)  "
        let continuation = "     "
        for word in words {
            let candidate = line == "  \(marker)  " ? line + word : line + " " + word
            if candidate.count <= width {
                line = candidate
            } else {
                result.append((line, color))
                line = continuation + word
            }
        }
        result.append((line, color))
        return result
    }

    private func renderPulse() {
        let height = terminalSize().height
        let orbit = ["· ◌ ·", "• ◌ ·", "· ◉ •", "· ◌ •"][animationFrame % 4]
        let orb: String
        switch microphoneLevel {
        case 0..<0.04: orb = "◌"
        case 0..<0.20: orb = "◍"
        case 0..<0.60: orb = "◉"
        default: orb = "●"
        }
        writeRow(height - 2, "  \(orbit)  \(orb)   Listening for Codex", color: violet)
    }
}

final class TurnCoordinator {
    private let ui: TerminalUI
    private var onResponseWindow: (() -> Void)?
    private var userActiveUntil = Date.distantPast
    private var systemActiveUntil = Date.distantPast
    private var waitingForCodexUntil = Date.distantPast
    private var hasHeardCodexSinceWake = false
    private var lastRenderedState = ""
    private var timer: Timer?

    init(ui: TerminalUI) {
        self.ui = ui
    }

    func setResponseWindowHandler(_ handler: @escaping () -> Void) {
        onResponseWindow = handler
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func heardUserAudio(level: Double) {
        guard level > 0.06 else { return }
        userActiveUntil = Date().addingTimeInterval(0.45)
    }

    func heardSystemAudio(level: Double) {
        guard level > 0.025 else { return }
        systemActiveUntil = Date().addingTimeInterval(0.55)
        hasHeardCodexSinceWake = true
    }

    func sentWakeShortcut() {
        waitingForCodexUntil = Date().addingTimeInterval(12)
        hasHeardCodexSinceWake = false
        onResponseWindow?()
        refresh()
    }

    private func refresh() {
        let now = Date()
        let state: String
        if systemActiveUntil > now {
            state = "Codex is speaking"
        } else if userActiveUntil > now {
            state = "You are speaking"
        } else if waitingForCodexUntil > now, !hasHeardCodexSinceWake {
            state = "Codex is thinking"
        } else {
            state = "Listening for your voice"
        }
        guard state != lastRenderedState else { return }
        lastRenderedState = state
        ui.renderTurn(state)
    }
}

final class SystemSpeechTranscriber {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))!
    private let onTranscript: (String) -> Void
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastTranscript = ""

    init(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
    }

    func start() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        task?.cancel()
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = newRequest
        lastTranscript = ""
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, _ in
            guard let self,
                  let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text != self.lastTranscript else { return }
            self.lastTranscript = text
            DispatchQueue.main.async {
                self.onTranscript(text)
            }
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    func stop() {
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }
}

final class SystemAudioMonitor: NSObject, SCStreamOutput {
    private let onLevel: (Double) -> Void
    private let onPermissionNeeded: () -> Void
    private let onCaptureStarted: () -> Void
    private let onCaptureStopped: () -> Void
    private let onSampleBuffer: (CMSampleBuffer) -> Void
    private var stream: SCStream?
    private var lastMeterUpdate = Date.distantPast
    private var responseWindowEnds = Date.distantPast
    private var stopTimer: Timer?
    private var isStarting = false
    private let sampleQueue = DispatchQueue(label: "local.voicecue.system-audio", qos: .utility)

    init(
        onLevel: @escaping (Double) -> Void,
        onPermissionNeeded: @escaping () -> Void,
        onCaptureStarted: @escaping () -> Void,
        onCaptureStopped: @escaping () -> Void,
        onSampleBuffer: @escaping (CMSampleBuffer) -> Void
    ) {
        self.onLevel = onLevel
        self.onPermissionNeeded = onPermissionNeeded
        self.onCaptureStarted = onCaptureStarted
        self.onCaptureStopped = onCaptureStopped
        self.onSampleBuffer = onSampleBuffer
    }

    func activateForResponseWindow() {
        responseWindowEnds = Date().addingTimeInterval(60)
        startStopTimerIfNeeded()
        guard stream == nil, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            onPermissionNeeded()
            _ = CGRequestScreenCaptureAccess()
            return
        }
        isStarting = true
        let captureStarted = onCaptureStarted
        let levelHandler = onLevel
        Task { [weak self, captureStarted, levelHandler] in
            guard let self else { return }
            defer { self.isStarting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                configuration.width = 2
                configuration.height = 2
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                DispatchQueue.main.async {
                    captureStarted()
                }
            } catch {
                DispatchQueue.main.async {
                    levelHandler(0)
                }
            }
        }
    }

    private func startStopTimerIfNeeded() {
        guard stopTimer == nil else { return }
        stopTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.stopWhenIdle()
        }
    }

    private func stopWhenIdle() {
        let now = Date()
        guard now >= responseWindowEnds else { return }
        stopTimer?.invalidate()
        stopTimer = nil
        guard let stream else { return }
        self.stream = nil
        onCaptureStopped()
        Task {
            try? await stream.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onSampleBuffer(sampleBuffer)
        guard Date().timeIntervalSince(lastMeterUpdate) > 0.08 else { return }
        lastMeterUpdate = Date()
        var audioBufferList = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        var retainedBlockBuffer: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard result == noErr,
              let data = audioBufferList.mBuffers.mData else { return }
        let count = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        var total = 0.0
        for index in 0..<count {
            let value = Double(samples[index])
            total += value * value
        }
        let rms = sqrt(total / Double(count))
        DispatchQueue.main.async { [weak self] in
            self?.onLevel(rms)
        }
    }
}

final class WakeWordListener: NSObject, SFSpeechRecognizerDelegate {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))!
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastTrigger = Date.distantPast
    private var hasTriggeredCurrentUtterance = false
    private var lastShownPrompt = ""
    private var lastMeterUpdate = Date.distantPast
    private var consecutiveStartFailures = 0
    private var isRestarting = false
    private let ui: TerminalUI
    private let turnCoordinator: TurnCoordinator

    init(ui: TerminalUI, turnCoordinator: TurnCoordinator) {
        self.ui = ui
        self.turnCoordinator = turnCoordinator
    }

    func start() {
        recognizer.delegate = self
        requestSpeechPermission()
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self?.ui.render(status: "Speech Recognition permission was not granted.")
                    fputs("Speech Recognition permission was not granted.\n", stderr)
                    exit(1)
                }
                self?.requestMicrophonePermission()
            }
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.ui.render(status: "Microphone permission was not granted.")
                    fputs("Microphone permission was not granted.\n", stderr)
                    exit(1)
                }
                self?.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        task?.cancel()
        hasTriggeredCurrentUtterance = false
        lastShownPrompt = ""
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest.contextualStrings = ["Codex", "Hey Codex"]
        request = recognitionRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            recognitionRequest.append(buffer)
            self?.updateMeter(from: buffer)
        }

        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString.lowercased() {
                self?.updateHeardWords(from: text)
                let isNewWakePhrase = self?.containsWakePhrase(text) == true
                    && self?.hasTriggeredCurrentUtterance == false
                if isNewWakePhrase {
                    self?.triggerPasteShortcut()
                }
                self?.updateSpokenPrompt(from: text)
                if isNewWakePhrase {
                    self?.turnCoordinator.sentWakeShortcut()
                }
            }
            if error != nil {
                self?.restartRecognitionSoon(afterFailure: true)
            } else if result?.isFinal == true {
                self?.restartRecognitionSoon(afterFailure: false)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            consecutiveStartFailures = 0
            isRestarting = false
            ui.renderMicrophone(level: 0)
            ui.render(status: "Listening now.")
        } catch {
            ui.render(status: "Could not start the microphone.")
            fputs("Could not start the microphone: \(error.localizedDescription)\n", stderr)
            restartRecognitionSoon(afterFailure: true)
        }
    }

    private func restartRecognitionSoon(afterFailure: Bool) {
        guard !isRestarting else { return }
        isRestarting = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        let delay: TimeInterval
        if afterFailure {
            delay = min(8, 0.25 * pow(2, Double(consecutiveStartFailures)))
            consecutiveStartFailures += 1
        } else {
            delay = 0.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isRestarting = false
            self?.beginRecognition()
        }
    }

    private func updateMeter(from buffer: AVAudioPCMBuffer) {
        guard Date().timeIntervalSince(lastMeterUpdate) > 0.08,
              let samples = buffer.floatChannelData?[0] else { return }
        lastMeterUpdate = Date()
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var total = 0.0
        for index in 0..<count {
            let sample = Double(samples[index])
            total += sample * sample
        }
        let rms = sqrt(total / Double(count))
        let normalized = min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60))
        DispatchQueue.main.async { [weak self] in
            self?.ui.renderMicrophone(level: normalized)
            self?.turnCoordinator.heardUserAudio(level: normalized)
        }
    }

    private func updateHeardWords(from transcript: String) {
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .suffix(2)
            .joined(separator: " ")
        DispatchQueue.main.async { [weak self] in
            self?.ui.renderHeard(words)
        }
    }

    private func updateSpokenPrompt(from transcript: String) {
        guard hasTriggeredCurrentUtterance else { return }
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        let wakeWords = Set(["codex", "codec", "kodak", "codak"])
        let prompt = words
            .drop { $0 == "hey" || wakeWords.contains($0) }
            .joined(separator: " ")
        guard !prompt.isEmpty, prompt != lastShownPrompt else { return }
        lastShownPrompt = prompt
        DispatchQueue.main.async { [weak self] in
            self?.ui.renderSpokenPrompt(prompt)
        }
    }

    private func containsWakePhrase(_ transcript: String) -> Bool {
        let normalizedWords = transcript
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
        let acceptedSoundAlikes = ["codex", "codec", "kodak", "codak"]
        return normalizedWords.contains { acceptedSoundAlikes.contains($0) }
    }

    private func triggerPasteShortcut() {
        guard Date().timeIntervalSince(lastTrigger) > 1.5 else { return }
        lastTrigger = Date()
        hasTriggeredCurrentUtterance = true
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskControl, .maskShift]
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.async { [weak self] in
            self?.ui.render(status: "Wake phrase heard — sent Control–Shift–V.")
        }
    }
}

let ui = TerminalUI()
ui.start()
let turnCoordinator = TurnCoordinator(ui: ui)
turnCoordinator.start()
let systemSpeechTranscriber = SystemSpeechTranscriber { transcript in
    ui.renderCodexSpeech(transcript)
}
let systemAudioMonitor = SystemAudioMonitor(
    onLevel: { level in
        turnCoordinator.heardSystemAudio(level: level)
    },
    onPermissionNeeded: {
        ui.render(status: "Allow Screen Recording to recognize when Codex speaks.")
    },
    onCaptureStarted: {
        systemSpeechTranscriber.start()
    },
    onCaptureStopped: {
        systemSpeechTranscriber.stop()
    },
    onSampleBuffer: { sampleBuffer in
        systemSpeechTranscriber.append(sampleBuffer)
    }
)
turnCoordinator.setResponseWindowHandler {
    systemAudioMonitor.activateForResponseWindow()
}
var listener: WakeWordListener?
var permissionTimer: Timer?

func beginWhenAccessibilityIsReady() {
    if AXIsProcessTrusted() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        ui.render(status: "Accessibility enabled — preparing microphone…")
        let newListener = WakeWordListener(ui: ui, turnCoordinator: turnCoordinator)
        listener = newListener
        newListener.start()
        return
    }

    ui.render(status: "Enable Accessibility in System Settings to start listening.")
}

let accessibilityOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
AXIsProcessTrustedWithOptions(accessibilityOptions)
beginWhenAccessibilityIsReady()
if listener == nil {
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        beginWhenAccessibilityIsReady()
    }
}
RunLoop.main.run()
