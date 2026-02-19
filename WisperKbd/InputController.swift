import Cocoa
import InputMethodKit

/// Main input controller for WisperKbd.
/// One instance is created per client (text input session).
@objc(InputController)
class InputController: IMKInputController {

    // MARK: - State

    private var isRecording = false
    private var compositionText = ""
    private var statusText = ""
    private let audioManager = AudioCaptureManager.shared
    private let whisperManager = WhisperManager.shared
    private var hasShownHint = false
    private var isTranscribing = false

    // MARK: - IMKInputController Lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        NSLog("WisperKbd: Input method activated")

        // Fix 4: Listen for model state changes
        whisperManager.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleWhisperStateChange(state, client: sender as? IMKTextInput)
            }
        }

        // Fix 2: Show usage hint on first activation
        if !hasShownHint, let client = sender as? IMKTextInput {
            hasShownHint = true
            showStatusHint(client: client)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        if isRecording {
            stopRecording(client: sender as? IMKTextInput)
        }
        whisperManager.onStateChange = nil
        super.deactivateServer(sender)
    }

    // MARK: - Event Handling

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        return Int(mask.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, let client = sender as? IMKTextInput else {
            return false
        }

        switch event.type {
        case .flagsChanged:
            return handleFlagsChanged(event, client: client)
        case .keyDown:
            return handleKeyDown(event, client: client)
        default:
            return false
        }
    }

    /// Toggle recording on right Option key.
    private func handleFlagsChanged(_ event: NSEvent, client: IMKTextInput) -> Bool {
        let rightOption = event.modifierFlags.contains(.option) && event.keyCode == 61

        if rightOption && !isRecording {
            startRecording(client: client)
            return true
        } else if !event.modifierFlags.contains(.option) && isRecording {
            stopRecording(client: client)
            return true
        }

        return false
    }

    private func handleKeyDown(_ event: NSEvent, client: IMKTextInput) -> Bool {
        // Escape cancels recording
        if isRecording && event.keyCode == 53 {
            cancelRecording(client: client)
            return true
        }
        // Consume keys while recording to avoid stray characters
        if isRecording {
            return true
        }
        return false
    }

    // MARK: - Usage Hint (Fix 2)

    private func showStatusHint(client: IMKTextInput) {
        let hint: String
        if !whisperManager.state.isReady {
            hint = whisperManager.state.displayText
        } else {
            hint = "Hold right Option to speak"
        }
        showTemporaryMarkedText(client: client, text: "[\(hint)]", duration: 3.0)
    }

    private func showTemporaryMarkedText(client: IMKTextInput, text: String, duration: TimeInterval) {
        statusText = text
        let attrStr = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .light)
        ])
        client.setMarkedText(attrStr,
                             selectionRange: NSRange(location: text.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, !self.isRecording, self.statusText == text else { return }
            self.statusText = ""
            client.setMarkedText("",
                                 selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
    }

    // MARK: - Whisper State Handling (Fix 4)

    private func handleWhisperStateChange(_ state: WhisperState, client: IMKTextInput?) {
        guard let client = client, !isRecording else { return }
        switch state {
        case .downloading:
            showTemporaryMarkedText(client: client, text: "[Downloading speech model...]", duration: 60)
        case .loading:
            showTemporaryMarkedText(client: client, text: "[Loading speech model...]", duration: 30)
        case .ready:
            showTemporaryMarkedText(client: client, text: "[Ready — hold right Option to speak]", duration: 3.0)
        case .failed(let error):
            showTemporaryMarkedText(client: client, text: "[Model error: \(error.localizedDescription)]", duration: 10)
        case .notLoaded:
            break
        }
    }

    // MARK: - Recording Control

    private func startRecording(client: IMKTextInput) {
        guard !isRecording else { return }

        // Fix 4: Check model readiness
        guard whisperManager.state.isReady else {
            let msg = whisperManager.state.displayText
            showTemporaryMarkedText(client: client, text: "[Cannot record: \(msg)]", duration: 3.0)
            NSLog("WisperKbd: Cannot start recording — \(msg)")
            return
        }

        isRecording = true
        compositionText = ""
        isTranscribing = false
        NSLog("WisperKbd: Recording started")

        // Fix 4: Show listening status
        updateMarkedText(client: client, text: "[Listening...]", isStatus: true)

        // Fix 3: Audio manager now sends FULL session buffer each time
        audioManager.startCapture { [weak self] fullSessionSamples in
            self?.processAudio(samples: fullSessionSamples, client: client)
        }
    }

    private func stopRecording(client: IMKTextInput?) {
        guard isRecording else { return }
        isRecording = false
        NSLog("WisperKbd: Recording stopped")

        audioManager.stopCapture()

        // Fix 3 + 4: Final transcription of FULL session audio
        let fullAudio = audioManager.drainBuffer()
        if !fullAudio.isEmpty {
            // Show processing indicator
            if let client = client {
                updateMarkedText(client: client, text: compositionText.isEmpty
                    ? "[Processing...]"
                    : "\(compositionText) [...]", isStatus: compositionText.isEmpty)
            }
            whisperManager.transcribe(samples: fullAudio) { [weak self] text in
                DispatchQueue.main.async {
                    self?.commitFinalText(client: client, text: text)
                }
            }
        } else if !compositionText.isEmpty {
            commitFinalText(client: client, text: compositionText)
        } else {
            clearMarkedText(client: client)
        }
    }

    private func cancelRecording(client: IMKTextInput) {
        isRecording = false
        compositionText = ""
        isTranscribing = false
        audioManager.stopCapture()
        _ = audioManager.drainBuffer()
        clearMarkedText(client: client)
        NSLog("WisperKbd: Recording cancelled")
    }

    // MARK: - Audio Processing (Fix 3)

    /// Called with the FULL session audio each time. Whisper re-transcribes
    /// everything so it has context across the entire utterance.
    private func processAudio(samples: [Float], client: IMKTextInput) {
        guard isRecording else { return }

        // Skip if a transcription is already in flight
        guard !isTranscribing else { return }
        isTranscribing = true

        whisperManager.transcribe(samples: samples) { [weak self] text in
            guard let self = self, self.isRecording else {
                self?.isTranscribing = false
                return
            }
            DispatchQueue.main.async {
                self.compositionText = text
                self.updateMarkedText(client: client, text: text, isStatus: false)
                self.isTranscribing = false
            }
        }
    }

    // MARK: - Text Output

    private func updateMarkedText(client: IMKTextInput, text: String, isStatus: Bool) {
        let attrs: [NSAttributedString.Key: Any]
        if isStatus {
            attrs = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .light)
            ]
        } else {
            attrs = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.textColor
            ]
        }
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        client.setMarkedText(attrStr,
                             selectionRange: NSRange(location: text.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func clearMarkedText(client: IMKTextInput?) {
        client?.setMarkedText("",
                              selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func commitFinalText(client: IMKTextInput?, text: String) {
        guard let client = client, !text.isEmpty else {
            clearMarkedText(client: client)
            return
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        compositionText = ""
        NSLog("WisperKbd: Committed text: \(text)")
    }

    // MARK: - Composition (IMKit)

    override func composedString(_ sender: Any!) -> Any! {
        return compositionText
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        commitFinalText(client: client, text: compositionText)
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "WisperKbd")

        // Header
        let statusItem = NSMenuItem(title: "WisperKbd v0.1", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Model status
        let stateText = whisperManager.state.displayText
        let stateItem = NSMenuItem(title: "Status: \(stateText)", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(NSMenuItem.separator())

        // Model selection submenu
        let modelMenu = NSMenu(title: "Model")
        for model in WhisperModel.allCases {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model
            if model == whisperManager.currentModel {
                item.state = .on
            }
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Language selection submenu
        let langMenu = NSMenu(title: "Language")
        for lang in WhisperLanguage.supported {
            let item = NSMenuItem(
                title: lang.name,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            if whisperManager.language == lang.code {
                item.state = .on
            }
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(NSMenuItem.separator())

        // Usage hints
        let hintItem = NSMenuItem(title: "Hold right Option to speak", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        let escItem = NSMenuItem(title: "Press Esc to cancel", action: nil, keyEquivalent: "")
        escItem.isEnabled = false
        menu.addItem(escItem)

        return menu
    }

    // MARK: - Menu Actions

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? WhisperModel else { return }
        NSLog("WisperKbd: User selected model: \(model.displayName)")
        whisperManager.selectModel(model)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        let name = WhisperLanguage.supported.first { $0.code == code }?.name ?? "Auto-detect"
        NSLog("WisperKbd: User selected language: \(name)")
        whisperManager.language = code
    }
}
