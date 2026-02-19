import AVFoundation

/// Captures microphone audio and resamples to 16kHz mono Float32 for Whisper.
/// Keeps the full session audio buffer so Whisper transcribes with full context.
class AudioCaptureManager {
    static let shared = AudioCaptureManager()

    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?

    /// Full session audio buffer (16kHz mono Float32)
    private var sessionBuffer: [Float] = []
    private let bufferLock = NSLock()

    /// Target format: 16kHz, mono, Float32 (what Whisper expects)
    private let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Whisper max context is ~30 seconds = 480000 samples at 16kHz
    private let maxSessionSamples = 16000 * 30

    /// Trigger transcription every ~1.5 seconds of new audio
    private let transcriptionInterval = 16000 * 3 / 2
    private var samplesSinceLastTranscription = 0

    private init() {}

    // MARK: - Public Interface

    /// Start capturing audio from the microphone.
    /// `onAudioUpdate` is called with the FULL session audio buffer each time
    /// enough new audio accumulates (so Whisper can re-transcribe with context).
    func startCapture(onAudioUpdate: @escaping ([Float]) -> Void) {
        bufferLock.lock()
        sessionBuffer.removeAll(keepingCapacity: true)
        samplesSinceLastTranscription = 0
        bufferLock.unlock()

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            NSLog("WisperKbd: ERROR — No audio input available (sample rate = 0)")
            return
        }

        audioConverter = AVAudioConverter(from: inputFormat, to: whisperFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            let samples = self.convertToWhisperFormat(buffer: buffer, inputFormat: inputFormat)
            guard !samples.isEmpty else { return }

            self.bufferLock.lock()
            self.sessionBuffer.append(contentsOf: samples)
            self.samplesSinceLastTranscription += samples.count

            // If session exceeds 30s, trim from the front (keep last 25s for overlap)
            if self.sessionBuffer.count > self.maxSessionSamples {
                let trimCount = self.sessionBuffer.count - (16000 * 25)
                self.sessionBuffer.removeFirst(trimCount)
            }

            let shouldTranscribe = self.samplesSinceLastTranscription >= self.transcriptionInterval
            var fullBuffer: [Float]? = nil
            if shouldTranscribe {
                fullBuffer = self.sessionBuffer
                self.samplesSinceLastTranscription = 0
            }
            self.bufferLock.unlock()

            if let fullBuffer = fullBuffer {
                onAudioUpdate(fullBuffer)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            NSLog("WisperKbd: Audio capture started (input: \(inputFormat.sampleRate)Hz -> 16000Hz)")
        } catch {
            NSLog("WisperKbd: ERROR — Failed to start audio engine: \(error)")
        }
    }

    /// Stop capturing audio.
    func stopCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        NSLog("WisperKbd: Audio capture stopped")
    }

    /// Return the full session audio buffer (for final transcription on stop).
    func getSessionBuffer() -> [Float] {
        bufferLock.lock()
        let buffer = sessionBuffer
        bufferLock.unlock()
        return buffer
    }

    /// Drain and clear the session buffer.
    func drainBuffer() -> [Float] {
        bufferLock.lock()
        let remaining = sessionBuffer
        sessionBuffer.removeAll(keepingCapacity: true)
        samplesSinceLastTranscription = 0
        bufferLock.unlock()
        return remaining
    }

    // MARK: - Private

    private func convertToWhisperFormat(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) -> [Float] {
        guard let converter = audioConverter else { return [] }

        let ratio = whisperFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return [] }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: whisperFormat,
            frameCapacity: outputFrameCount
        ) else { return [] }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            NSLog("WisperKbd: Audio conversion error: \(error)")
            return []
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}
