import Cocoa
import Speech
import AVFoundation

// Push-to-talk dictation: hold 🌐 (Fn/Globe) while Suit is focused to speak,
// release to drop the recognized text into the focused terminal pane's prompt
// (SessionControl.send, submit:false — you review before Enter). The Fn hold is
// watched by AppDelegate+Dictation's local flagsChanged monitor; this file owns
// the recognizer, the mic tap, and the "Listening…" HUD. The pure transcript
// cleanup lives in DictationText.swift (harness-tested).
//
// On-device recognition (SFSpeechRecognizer.requiresOnDeviceRecognition) keeps
// audio off the network — no API key, private, works offline once the language
// model is present. First use prompts for microphone + speech-recognition
// access (Info.plist NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription).
final class DictationController {
    static let shared = DictationController()

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var isListening = false
    private var didDeliver = false
    private var latestTranscript = ""
    private var target: TerminalPaneContent?
    private var finalTimer: Timer?

    private let hud = DictationHUD()

    private init() {}

    // Fn pressed: begin listening into `terminal` (nil → nothing focused). The
    // HUD anchors over `window`. Authorization is requested lazily on first use;
    // if it isn't granted yet the request dialog appears and this press is a
    // no-op (the next hold works once granted).
    func begin(into terminal: TerminalPaneContent?, over window: NSWindow?) {
        guard !isListening else { return }
        guard let terminal else {
            hud.show(caption: "🎙 DICTATION", message: "No terminal focused", over: window)
            hud.dismiss(after: 1.2)
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            hud.show(caption: "🎙 DICTATION", message: "Speech recognition unavailable", over: window)
            hud.dismiss(after: 1.6)
            return
        }

        ensureAuthorized { [weak self] granted, message in
            guard let self else { return }
            guard granted else {
                self.hud.show(caption: "🎙 DICTATION", message: message ?? "Microphone access denied", over: window)
                self.hud.dismiss(after: 2.0)
                return
            }
            self.startListening(into: terminal, over: window)
        }
    }

    // Fn released: stop the mic, flush the recognizer, and inject the final
    // transcript. The recognizer delivers its final result asynchronously after
    // endAudio(), so we wait briefly, falling back to the last partial.
    func finish() {
        guard isListening else { return }
        isListening = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()

        hud.setMessage(latestTranscript.isEmpty ? "…" : latestTranscript, dim: true)

        // Give the recognizer a moment to emit its final transcription; if it
        // doesn't, deliver whatever the last partial was.
        finalTimer?.invalidate()
        finalTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.deliver()
        }
    }

    // MARK: - Recognition

    private func startListening(into terminal: TerminalPaneContent, over window: NSWindow?) {
        // Tear down any half-open previous run before starting fresh.
        task?.cancel()
        task = nil
        finalTimer?.invalidate()
        finalTimer = nil

        target = terminal
        latestTranscript = ""
        didDeliver = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            hud.show(caption: "🎙 DICTATION", message: "Couldn’t start microphone", over: window)
            hud.dismiss(after: 1.6)
            return
        }

        isListening = true
        hud.show(caption: "🎙 LISTENING — RELEASE 🌐 TO INSERT", message: "…", over: window)

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    if !self.latestTranscript.isEmpty {
                        self.hud.setMessage(self.latestTranscript, dim: false)
                    }
                    if result.isFinal { self.deliver() }
                }
                // An error after we've stopped is the normal end-of-stream; only
                // a mid-listen error should surface. Either way, deliver what we
                // have so a hold never hangs the HUD.
                if error != nil { self.deliver() }
            }
        }
    }

    // Inject the cleaned transcript once, then reset. Guarded so the final
    // callback and the timeout can't both fire the paste.
    private func deliver() {
        guard !didDeliver else { return }
        didDeliver = true
        finalTimer?.invalidate()
        finalTimer = nil
        task?.cancel()
        task = nil
        request = nil

        let text = DictationText.normalize(latestTranscript)
        let terminal = target
        target = nil

        if !text.isEmpty, let terminal {
            SessionControl.send(text: text, to: terminal, submit: false)
        }
        hud.dismiss(after: text.isEmpty ? 0.3 : 0.12)
    }

    // The ⌘K entry ("Dictate…"): it can't hold a key for you, so it primes
    // authorization on first use and reminds you of the 🌐 hold gesture.
    func primeFromPalette(over window: NSWindow?) {
        ensureAuthorized { [weak self] granted, message in
            guard let self else { return }
            if granted {
                self.hud.show(caption: "🎙 DICTATION", message: "Hold 🌐 (Globe) to talk", over: window)
                self.hud.dismiss(after: 2.0)
            } else {
                self.hud.show(caption: "🎙 DICTATION", message: message ?? "Access denied", over: window)
                self.hud.dismiss(after: 2.4)
            }
        }
    }

    // MARK: - Authorization

    private func ensureAuthorized(_ completion: @escaping (Bool, String?) -> Void) {
        requestSpeechAuth { speechOK, speechMsg in
            guard speechOK else { completion(false, speechMsg); return }
            self.requestMicAuth { micOK in
                completion(micOK, micOK ? nil : "Microphone access denied — enable it in System Settings → Privacy")
            }
        }
    }

    private func requestSpeechAuth(_ completion: @escaping (Bool, String?) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true, nil)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized, nil) }
            }
        default:
            completion(false, "Speech recognition denied — enable it in System Settings → Privacy")
        }
    }

    private func requestMicAuth(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }
}

// A small borderless floating panel echoing the ⌃Tab switcher's flat overlay
// look (Theme.overlay + hairline). Never becomes key — focus stays in the pane
// so the injected text lands where the cursor already is.
private final class DictationHUD {
    private var panel: NSPanel?
    private var caption: NSTextField?
    private var message: NSTextField?
    private var dismissTimer: Timer?

    func show(caption text: String, message initial: String, over window: NSWindow?) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        let width: CGFloat = 380
        let height: CGFloat = 74

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.overlay.cgColor
        content.layer?.cornerRadius = Theme.Metrics.overlayRadius
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Theme.hairline.cgColor

        let cap = NSTextField(labelWithString: "")
        cap.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: Theme.captionFont,
                .foregroundColor: Theme.accent,
                .kern: Theme.captionKern,
            ]
        )
        cap.frame = NSRect(x: 16, y: height - 28, width: width - 32, height: 14)
        content.addSubview(cap)
        caption = cap

        let msg = NSTextField(labelWithString: initial)
        msg.font = .systemFont(ofSize: 13, weight: .regular)
        msg.textColor = Theme.textPrimary
        msg.lineBreakMode = .byTruncatingHead
        msg.frame = NSRect(x: 16, y: 14, width: width - 32, height: 20)
        content.addSubview(msg)
        message = msg

        let panel = self.panel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: width, height: height))

        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2))
        } else {
            panel.center()
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func setMessage(_ text: String, dim: Bool) {
        message?.stringValue = text
        message?.textColor = dim ? Theme.textDim : Theme.textPrimary
    }

    func dismiss(after delay: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.panel?.orderOut(nil)
        }
    }
}
