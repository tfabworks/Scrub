//
//  WebSpeechSynth.swift
//  ScratchWebKit
//
//  Bridges the Web Speech API (speechSynthesis) to the native
//  AVSpeechSynthesizer. On iOS/WKWebView the Web Speech `pitch` is ignored by
//  the Apple voices, so character voices (high/low pitch) don't work; the
//  native AVSpeechUtterance.pitchMultiplier honours pitch correctly.
//

import WebKit
import AVFoundation

enum SpeechSynthMessageName: String {
    case synthSpeak
    case synthCancel
}

public class WebSpeechSynth: NSObject {

    private weak var webView: WKWebView?
    private let synthesizer = AVSpeechSynthesizer()

    // Map each spoken utterance to the JS-side id so we can notify completion.
    private var ids: [ObjectIdentifier: Int] = [:]

    public func setup(webView: WKWebView) {
        guard let filepath = Bundle.module.path(forResource: "synth-inject", ofType: "js"),
              let js = try? String(contentsOfFile: filepath) else { return }
        let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(script)

        webView.configuration.userContentController.add(self, name: SpeechSynthMessageName.synthSpeak.rawValue)
        webView.configuration.userContentController.add(self, name: SpeechSynthMessageName.synthCancel.rawValue)

        self.webView = webView
        synthesizer.delegate = self
    }

    public func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func sendEnd(_ id: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.WebSpeechSynthKit && WebSpeechSynthKit.coordinator.receiveEnd(\(id))")
        }
    }
}

// MARK: - JS bridge in

extension WebSpeechSynth: WKScriptMessageHandler {

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let name = SpeechSynthMessageName(rawValue: message.name) else { return }

        switch name {
        case .synthSpeak:
            guard let params = message.body as? [String: Any],
                  let id = params["id"] as? Int else { return }
            let text = params["text"] as? String ?? ""
            let lang = params["lang"] as? String ?? ""
            let pitch = (params["pitch"] as? NSNumber)?.doubleValue ?? 1.0
            let rate = (params["rate"] as? NSNumber)?.doubleValue ?? 1.0

            // Stop anything currently speaking before starting a new utterance.
            synthesizer.stopSpeaking(at: .immediate)

            let utterance = AVSpeechUtterance(string: text)
            if !lang.isEmpty, let voice = AVSpeechSynthesisVoice(language: lang) {
                utterance.voice = voice
            }
            // pitchMultiplier valid range is 0.5...2.0 (clamp e.g. giant 0.4 -> 0.5).
            utterance.pitchMultiplier = Float(min(2.0, max(0.5, pitch)))
            // Map the Web Speech rate (0.1...10, default 1) onto AVSpeechUtterance's rate.
            let avRate = Double(AVSpeechUtteranceDefaultSpeechRate) * rate
            utterance.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate),
                                       max(Double(AVSpeechUtteranceMinimumSpeechRate), avRate)))

            ids[ObjectIdentifier(utterance)] = id
            synthesizer.speak(utterance)

        case .synthCancel:
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

// MARK: - AVSpeechSynthesizer delegate

extension WebSpeechSynth: AVSpeechSynthesizerDelegate {

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    private func finish(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let id = ids[key] else { return }
        ids.removeValue(forKey: key)
        sendEnd(id)
    }
}
