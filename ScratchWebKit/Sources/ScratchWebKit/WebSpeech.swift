//
//  WebSpeech.swift
//  ScratchWebKit
//
//  Bridges the Web Speech API (SpeechRecognition) to the native
//  SFSpeechRecognizer so that speech recognition works inside the
//  WKWebView (where WebKit's own SpeechRecognition only returns "aborted").
//

import WebKit
import Speech
import AVFoundation

enum SpeechMessageName: String {
    case speechStart
    case speechStop
    case speechAbort
}

public class WebSpeech: NSObject {

    private weak var webView: WKWebView?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var currentId: Int = 0
    private var isRunning = false
    private var isAborting = false
    private var gotResult = false
    private var continuous = false
    private var reportPartial = false
    private var lastTranscript = ""

    private var silenceWork: DispatchWorkItem?
    private var noSpeechWork: DispatchWorkItem?

    // Auto-stop after this much silence (non-continuous mode).
    private let silenceTimeout = 1.6
    // Give up if no speech is detected at all.
    private let noSpeechTimeout = 6.0

    public func setup(webView: WKWebView) {
        guard let filepath = Bundle.module.path(forResource: "speech-inject", ofType: "js"),
              let js = try? String(contentsOfFile: filepath) else { return }
        let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)

        webView.configuration.userContentController.add(self, name: SpeechMessageName.speechStart.rawValue)
        webView.configuration.userContentController.add(self, name: SpeechMessageName.speechStop.rawValue)
        webView.configuration.userContentController.add(self, name: SpeechMessageName.speechAbort.rawValue)

        self.webView = webView
    }

    public func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.abortInternal(sendEnd: true)
        }
    }
}

// MARK: - Recognition lifecycle

extension WebSpeech {

    private func start(id: Int, lang: String, interim: Bool, continuous: Bool) {
        // Stop any previous session silently.
        abortInternal(sendEnd: false)

        currentId = id
        isAborting = false
        gotResult = false
        reportPartial = interim
        self.continuous = continuous
        lastTranscript = ""

        let localeId = lang.isEmpty ? (Locale.preferredLanguages.first ?? "en-US") : lang
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) else {
            sendError(id, "language-not-supported")
            sendEnd(id)
            return
        }
        guard recognizer.isAvailable else {
            sendError(id, "service-not-allowed")
            sendEnd(id)
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, self.currentId == id else { return }
                guard status == .authorized else {
                    self.sendError(id, "not-allowed")
                    self.sendEnd(id)
                    return
                }
                self.requestMicrophone(id: id, recognizer: recognizer)
            }
        }
    }

    private func requestMicrophone(id: Int, recognizer: SFSpeechRecognizer) {
        let onResult: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self, self.currentId == id else { return }
                if granted {
                    self.beginRecognition(id: id, recognizer: recognizer)
                } else {
                    self.sendError(id, "not-allowed")
                    self.sendEnd(id)
                }
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: onResult)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(onResult)
        }
    }

    private func beginRecognition(id: Int, recognizer: SFSpeechRecognizer) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            sendError(id, "audio-capture")
            sendEnd(id)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true // needed to drive the silence timer
        self.request = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // The audio route can be momentarily unavailable (0 channels / 0 Hz)
        // when a new recognition starts right after a previous one was torn
        // down. Installing a tap with such a format makes AVAudioEngine throw
        // an Objective-C exception that can't be caught in Swift, aborting the
        // whole app. Bail out gracefully instead of crashing.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            stopAudio()
            sendError(id, "audio-capture")
            sendEnd(id)
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stopAudio()
            sendError(id, "audio-capture")
            sendEnd(id)
            return
        }

        isRunning = true
        sendStart(id)
        scheduleNoSpeech(id: id)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning, self.currentId == id else { return }

                if let result = result {
                    self.gotResult = true
                    self.cancelNoSpeech()
                    self.lastTranscript = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    if isFinal || self.reportPartial {
                        self.sendResult(id, self.lastTranscript, isFinal)
                    }
                    if isFinal {
                        self.finishSuccess(id: id)
                    } else {
                        self.scheduleSilence(id: id)
                    }
                }

                if let error = error {
                    if self.isAborting { return }
                    self.handleTaskError(id: id, error: error as NSError)
                }
            }
        }
    }
}

// MARK: - Stop / cleanup

extension WebSpeech {

    private func finishSuccess(id: Int) {
        cancelSilence()
        cancelNoSpeech()
        stopAudio()
        resetState()
        sendEnd(id)
    }

    private func handleTaskError(id: Int, error: NSError) {
        cancelSilence()
        cancelNoSpeech()
        if gotResult {
            // Finalize with the best transcript captured so far.
            sendResult(id, lastTranscript, true)
        } else {
            sendError(id, mapError(error))
        }
        stopAudio()
        resetState()
        sendEnd(id)
    }

    private func abortInternal(sendEnd doSendEnd: Bool) {
        guard isRunning else { return }
        isAborting = true
        cancelSilence()
        cancelNoSpeech()
        task?.cancel()
        request?.endAudio()
        stopAudio()
        let id = currentId
        resetState()
        if doSendEnd {
            sendEnd(id)
        }
    }

    private func stopAudio() {
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetState() {
        isRunning = false
        isAborting = false
        gotResult = false
        task = nil
        request = nil
        lastTranscript = ""
    }

    private func mapError(_ error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            return "network"
        }
        if error.domain == "kAFAssistantErrorDomain" {
            switch error.code {
            case 1110, 1700, 203: return "no-speech"
            default: break
            }
        }
        return "no-speech"
    }
}

// MARK: - Timers

extension WebSpeech {

    private func scheduleNoSpeech(id: Int) {
        cancelNoSpeech()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning, self.currentId == id, !self.gotResult else { return }
            self.isAborting = true
            self.task?.cancel()
            self.stopAudio()
            self.resetState()
            self.sendError(id, "no-speech")
            self.sendEnd(id)
        }
        noSpeechWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + noSpeechTimeout, execute: work)
    }

    private func scheduleSilence(id: Int) {
        if continuous { return }
        cancelSilence()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning, self.currentId == id else { return }
            // End audio so the recognizer emits a final result; keep the task alive to receive it.
            self.request?.endAudio()
            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
        }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeout, execute: work)
    }

    private func cancelSilence() {
        silenceWork?.cancel()
        silenceWork = nil
    }

    private func cancelNoSpeech() {
        noSpeechWork?.cancel()
        noSpeechWork = nil
    }
}

// MARK: - JS bridge out

extension WebSpeech {

    private func evalJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js)
        }
    }

    private func jsLiteral(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\"\""
    }

    private func sendStart(_ id: Int) {
        evalJS("window.WebSpeechKit && WebSpeechKit.coordinator.receiveStart(\(id))")
    }

    private func sendResult(_ id: Int, _ transcript: String, _ isFinal: Bool) {
        lastTranscript = transcript
        evalJS("window.WebSpeechKit && WebSpeechKit.coordinator.receiveResult(\(id), \(jsLiteral(transcript)), \(isFinal))")
    }

    private func sendError(_ id: Int, _ error: String) {
        evalJS("window.WebSpeechKit && WebSpeechKit.coordinator.receiveError(\(id), \(jsLiteral(error)))")
    }

    private func sendEnd(_ id: Int) {
        evalJS("window.WebSpeechKit && WebSpeechKit.coordinator.receiveEnd(\(id))")
    }
}

// MARK: - JS bridge in

extension WebSpeech: WKScriptMessageHandler {

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let name = SpeechMessageName(rawValue: message.name),
              let params = message.body as? [String: Any] else { return }

        switch name {
        case .speechStart:
            guard let id = params["id"] as? Int else { return }
            let lang = params["lang"] as? String ?? ""
            let interim = params["interimResults"] as? Bool ?? false
            let continuous = params["continuous"] as? Bool ?? false
            start(id: id, lang: lang, interim: interim, continuous: continuous)

        case .speechStop:
            guard let id = params["id"] as? Int, id == currentId, isRunning else { return }
            request?.endAudio()

        case .speechAbort:
            guard let id = params["id"] as? Int, id == currentId else { return }
            abortInternal(sendEnd: true)
        }
    }
}
