import ApplicationServices
import AppKit
import AVFoundation
import Darwin
import Foundation
import Speech
import Vision

final class TerminalUI {
    private let violet = "\u{001B}[38;5;141m"
    private let muted = "\u{001B}[38;5;244m"
    private let reset = "\u{001B}[0m"
    private var status = "Starting up…"
    private var heard = "—"
    private var microphoneLevel = 0.0
    private var codexState = "Waiting for Codex"
    private var codexLines = ["Open a Codex task to mirror visible activity here."]
    private var animationFrame = 0
    private var animationTimer: Timer?

    func start() {
        redraw()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
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

    func renderCodexActivity(state: String, lines: [String]) {
        codexState = state
        codexLines = lines.isEmpty ? ["No visible Codex activity yet."] : lines
        redrawCodexActivity()
    }

    private func terminalSize() -> (width: Int, height: Int) {
        var windowSize = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize)
        return (windowSize.ws_col > 0 ? Int(windowSize.ws_col) : 72,
                windowSize.ws_row > 0 ? Int(windowSize.ws_row) : 22)
    }

    private func writeRow(_ row: Int, _ text: String, color: String = "") {
        let width = terminalSize().width
        let clipped = String(text.prefix(width))
        print("\u{001B}[\(row);1H\(color)\(clipped)\(reset)\u{001B}[K", terminator: "")
        fflush(stdout)
    }

    private func redraw() {
        let size = terminalSize()
        let divider = String(repeating: "─", count: max(1, size.width))
        print("\u{001B}[?25l\u{001B}[2J\u{001B}[H", terminator: "")
        writeRow(2, "  ◜◝   VoiceCue", color: violet)
        writeRow(3, "        local wake phrase shortcut", color: muted)
        redrawCodexActivity()
        writeRow(size.height - 4, divider, color: muted)
        writeRow(size.height - 1, "  Control-C to stop", color: muted)
        redrawLiveArea()
        renderPulse()
    }

    private func redrawLiveArea() {
        let height = terminalSize().height
        writeRow(height - 3, "  \(status)   \(muted)· Heard: \(heard)")
    }

    private func redrawCodexActivity() {
        let height = terminalSize().height
        let firstRow = max(6, height - 14)
        writeRow(firstRow, "  CODEX SESSION  \(muted)· \(codexState)", color: violet)
        for offset in 0..<8 {
            let line = offset < codexLines.count ? codexLines[offset] : ""
            writeRow(firstRow + offset + 1, "    \(line)", color: offset == 0 ? reset : muted)
        }
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

final class CodexActivityMirror {
    private let onUpdate: (String, [String]) -> Void
    private var timer: Timer?
    private var lastSnapshot = ""
    private var hasRequestedScreenCapture = false

    init(onUpdate: @escaping (String, [String]) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let app = targetCodexApplication() else {
            onUpdate("Waiting for Codex", ["Open the Codex app to show visible activity."])
            return
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedElement = focusedWindow(for: applicationElement) ?? applicationElement
        let visibleText = collectText(from: focusedElement, depth: 0)
        let ignoredChrome = Set(["Documentation", "Keyboard Shortcuts", "What's New", "Troubleshooting", "System Status", "Send Feedback", "Task Manager", "Start Performance Trace"])
        let rawLines = visibleText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 2 && !ignoredChrome.contains($0) }
        var seen = Set<String>()
        let lines = rawLines.filter { seen.insert($0).inserted }.suffix(8)

        guard !lines.isEmpty else {
            mirrorWindowTextWithOCR(app)
            return
        }

        let snapshot = lines.joined(separator: "\n")
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            onUpdate("Mirroring visible activity", Array(lines))
        }
    }

    private func mirrorWindowTextWithOCR(_ app: NSRunningApplication) {
        guard CGPreflightScreenCaptureAccess() else {
            if !hasRequestedScreenCapture {
                hasRequestedScreenCapture = true
                _ = CGRequestScreenCaptureAccess()
            }
            onUpdate("Screen Recording required", ["Allow Screen Recording for VoiceCue to mirror visible Codex messages."])
            return
        }
        guard let window = targetWindow(for: app),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, window, .boundsIgnoreFraming) else {
            onUpdate("Codex open; no readable items", ["Bring the Codex conversation window on screen to mirror it."])
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let lines = request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.isEmpty }
                .suffix(8) ?? []
            let snapshot = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self else { return }
                if snapshot.isEmpty {
                    self.onUpdate("Codex visible; no text found", ["Waiting for visible Codex conversation text."])
                } else if snapshot != self.lastSnapshot {
                    self.lastSnapshot = snapshot
                    self.onUpdate("Mirroring visible conversation", Array(lines))
                }
            }
        }
    }

    private func targetWindow(for app: NSRunningApplication) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == app.processIdentifier,
                  let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    private func targetCodexApplication() -> NSRunningApplication? {
        let applications = NSWorkspace.shared.runningApplications
        let isCodexHost: (NSRunningApplication) -> Bool = { app in
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            return name == "chatgpt" || name == "codex" || bundle.contains("chatgpt") || bundle == "com.openai.codex"
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication, isCodexHost(frontmost) {
            return frontmost
        }
        return applications.first(where: { ($0.localizedName ?? "").lowercased() == "chatgpt" })
            ?? applications.first(where: isCodexHost)
    }

    private func focusedWindow(for applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as! AXUIElement
    }

    private func collectText(from element: AXUIElement, depth: Int) -> String {
        guard depth < 6 else { return "" }
        var parts = [String]()
        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String {
                parts.append(text)
            }
        }
        var childrenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                parts.append(collectText(from: child, depth: depth + 1))
            }
        }
        return parts.joined(separator: "\n")
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
            ui.renderMicrophone(level: 0)
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
let codexMirror = CodexActivityMirror { state, lines in
    ui.renderCodexActivity(state: state, lines: lines)
}
codexMirror.start()
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
