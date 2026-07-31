import ApplicationServices
import AVFoundation
import Darwin
import Foundation
import Speech

final class TerminalUI {
    private let violet = "\u{001B}[38;5;141m"
    private let green = "\u{001B}[38;5;114m"
    private let cyan = "\u{001B}[38;5;117m"
    private let muted = "\u{001B}[38;5;244m"
    private let panel = "\u{001B}[48;5;236m"
    private let header = "\u{001B}[48;5;60m"
    private let reset = "\u{001B}[0m"
    private var status = "Starting up…"
    private var heard = "—"
    private var microphoneLevel = 0.0
    private var animationFrame = 0
    private var animationTimer: Timer?

    func start() {
        redraw()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
            self?.animationFrame += 1
            self?.renderListeningPulse()
        }
    }

    func render(status: String) {
        self.status = status
        renderLiveRow(15, text: "  \(status)", color: reset)
    }

    func renderHeard(_ words: String) {
        heard = words.isEmpty ? "—" : words
        renderLiveRow(12, text: "     \(heard)", color: reset)
    }

    func renderMicrophone(level: Double) {
        microphoneLevel = min(max(level, 0), 1)
        let width = terminalSize().width
        let meterWidth = max(12, min(42, width - 30))
        let filled = Int((microphoneLevel * Double(meterWidth)).rounded())
        let percent = Int((microphoneLevel * 100).rounded())
        let label: String
        let activeColor: String
        switch percent {
        case 0..<8:
            label = "QUIET"
            activeColor = cyan
        case 8..<55:
            label = "ACTIVE"
            activeColor = green
        default:
            label = "LOUD"
            activeColor = violet
        }
        let active = String(repeating: "█", count: filled)
        let inactive = String(repeating: "─", count: meterWidth - filled)
        let prefix = "     \(String(format: "%3d", percent))%  \(label)  "
        let visibleLength = prefix.count + meterWidth
        let padding = max(0, width - visibleLength)
        print("\u{001B}[9;1H\(panel)\(cyan)\(prefix)\(activeColor)\(active)\(muted)\(inactive)\(reset)\(panel)\(String(repeating: " ", count: padding))\(reset)", terminator: "")
        fflush(stdout)
    }

    private func terminalSize() -> (width: Int, height: Int) {
        var windowSize = winsize()
        ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize)
        let width = windowSize.ws_col > 0 ? Int(windowSize.ws_col) : 72
        let height = windowSize.ws_row > 0 ? Int(windowSize.ws_row) : 22
        return (width, height)
    }

    private func renderLiveRow(_ row: Int, text: String, color: String) {
        let width = terminalSize().width
        let clipped = String(text.prefix(width))
        let padding = max(0, width - clipped.count)
        print("\u{001B}[\(row);1H\(panel)\(color)\(clipped)\(reset)\(panel)\(String(repeating: " ", count: padding))\(reset)", terminator: "")
        fflush(stdout)
    }

    private func redraw() {
        let size = terminalSize()
        let width = size.width
        let contentWidth = width - 4
        let rule = String(repeating: "─", count: contentWidth)
        let rows = [
            "",
            "  VoiceCue    /    hands-free shortcut control",
            "  \(rule)",
            "",
            listeningPulseText(),
            "     Say  Codex  or  Hey Codex",
            "",
            "  MICROPHONE",
            "     Waiting for microphone input…",
            "",
            "  LIVE TRANSCRIPT",
            "     \(heard)",
            "",
            "  STATUS",
            "     \(status)",
            "",
            "  ACTION    Control–Shift–V  →  frontmost app",
            "",
            "  Control-C to stop                                      voicecue update"
        ]

        print("\u{001B}[?25l\u{001B}[2J\u{001B}[H", terminator: "")
        for (index, row) in rows.enumerated() {
            let background = index < 3 ? header : panel
            let color: String
            switch index {
            case 1: color = violet
            case 4: color = green
            case 7, 10, 13: color = cyan
            case 18: color = muted
            default: color = reset
            }
            let clipped = String(row.prefix(width))
            let padding = max(0, width - clipped.count)
            print("\(background)\(color)\(clipped)\(reset)\(background)\(String(repeating: " ", count: padding))\(reset)")
        }
        for _ in rows.count..<size.height {
            print("\(panel)\(String(repeating: " ", count: width))\(reset)")
        }
        fflush(stdout)
    }

    private func listeningPulseText() -> String {
        let orbitFrames = ["·  ◌  ·", "•  ◌  ·", "·  ◉  •", "·  ◌  •"]
        let orb: String
        switch microphoneLevel {
        case 0..<0.03: orb = "◌"
        case 0..<0.18: orb = "◍"
        case 0..<0.55: orb = "◉"
        default: orb = "●"
        }
        return "  \(orbitFrames[animationFrame % orbitFrames.count])   \(orb)  LISTENING"
    }

    private func renderListeningPulse() {
        renderLiveRow(5, text: listeningPulseText(), color: violet)
    }
}

final class WakeWordListener: NSObject, SFSpeechRecognizerDelegate {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US"))!
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastTrigger = Date.distantPast
    private var hasTriggeredCurrentUtterance = false
    private var lastMeterUpdate = Date.distantPast
    private let ui: TerminalUI

    init(ui: TerminalUI) {
        self.ui = ui
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
                    return
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
                    return
                }
                self?.beginRecognition()
            }
        }
    }

    private func beginRecognition() {
        task?.cancel()
        hasTriggeredCurrentUtterance = false
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
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
                if self?.containsWakePhrase(text) == true,
                   self?.hasTriggeredCurrentUtterance == false {
                    self?.triggerPasteShortcut()
                }
            }
            if error != nil || result?.isFinal == true {
                self?.restartRecognitionSoon()
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            ui.render(status: "Listening now.")
        } catch {
            ui.render(status: "Could not start the microphone.")
            fputs("Could not start the microphone: \(error.localizedDescription)\n", stderr)
            restartRecognitionSoon()
        }
    }

    private func restartRecognitionSoon() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.beginRecognition() }
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
var listener: WakeWordListener?
var permissionTimer: Timer?

func beginWhenAccessibilityIsReady() {
    if AXIsProcessTrusted() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        ui.render(status: "Accessibility enabled — preparing microphone…")
        let newListener = WakeWordListener(ui: ui)
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
