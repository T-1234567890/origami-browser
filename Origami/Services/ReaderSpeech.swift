import Foundation
import AVFoundation
import Observation

struct ReaderSpeechOptions {
    var voiceID = ""
    var speed = 1.0
    var rate: Float { min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed.isFinite ? min(1.5, max(0.5, speed)) : 1))) }
}

@MainActor protocol ReaderSpeechEngine: AnyObject {
    func speak(_ text: String, options: ReaderSpeechOptions, completion: @escaping @MainActor () -> Void)
    func pause() -> Bool
    func resume() -> Bool
    func stop()
}

@MainActor final class SystemReaderSpeechEngine: NSObject, ReaderSpeechEngine, AVSpeechSynthesizerDelegate {
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let value = AVSpeechSynthesizer(); value.delegate = self; return value
    }()
    private var active: ObjectIdentifier?
    private var completion: (@MainActor () -> Void)?
    func speak(_ text: String, options: ReaderSpeechOptions, completion: @escaping @MainActor () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = options.voiceID.isEmpty && options.speed == 1
        if !options.voiceID.isEmpty { utterance.voice = AVSpeechSynthesisVoice(identifier: options.voiceID) }
        utterance.rate = options.rate
        active = ObjectIdentifier(utterance); self.completion = completion
        synthesizer.speak(utterance)
    }
    func pause() -> Bool { synthesizer.pauseSpeaking(at: .immediate) }
    func resume() -> Bool { synthesizer.continueSpeaking() }
    func stop() {
        guard active != nil else { return }
        active = nil; completion = nil; synthesizer.stopSpeaking(at: .immediate)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
    nonisolated private func finished(_ id: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, self.active == id else { return }
            self.active = nil
            let done = self.completion; self.completion = nil; done?()
        }
    }
}

@MainActor @Observable final class ReaderSpeech {
    enum State { case idle, speaking, paused }
    private(set) var state = State.idle
    @ObservationIgnored private let engine: any ReaderSpeechEngine
    @ObservationIgnored private var generation = UUID()
    private static weak var current: ReaderSpeech?
    init(engine: (any ReaderSpeechEngine)? = nil) { self.engine = engine ?? SystemReaderSpeechEngine() }
    func toggle(article: ReaderArticle, options: ReaderSpeechOptions = ReaderSpeechOptions()) {
        switch state {
        case .speaking: if engine.pause() { state = .paused }
        case .paused: if engine.resume() { state = .speaking }
        case .idle:
            let text = Self.text(for: article)
            guard !text.isEmpty else { return }
            Self.current?.stop(); Self.current = self
            generation = UUID(); let id = generation
            state = .speaking
            engine.speak(text, options: options) { [weak self] in
                guard let self, self.generation == id else { return }
                self.state = .idle
                if Self.current === self { Self.current = nil }
            }
        }
    }
    func stop() {
        generation = UUID(); engine.stop(); state = .idle
        if Self.current === self { Self.current = nil }
    }
    /// Speak rendered prose, not Markdown syntax, link destinations or media placeholders.
    static func text(for article: ReaderArticle) -> String {
        let paragraphs = article.markdown.components(separatedBy: "\n\n").compactMap { paragraph -> String? in
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if article.mediaBlock(value) != nil || value.hasPrefix("[origami-media:") { return nil }
            let prose = value.replacingOccurrences(of: #"(?m)^\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            let rendered = (try? AttributedString(markdown: prose, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                .map { String($0.characters) } ?? prose
            return rendered.isEmpty ? nil : rendered
        }
        return ([article.title.trimmingCharacters(in: .whitespacesAndNewlines)] + paragraphs)
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
