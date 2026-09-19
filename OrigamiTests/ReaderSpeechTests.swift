import Testing
@testable import Origami

@MainActor struct ReaderSpeechTests {
    private var article: ReaderArticle { .init(title: "Title", author: "", date: "", markdown: "## Heading\n\n**Hello** [world](https://example.invalid).\n\n[origami-media:0]") }
    @Test func spokenTextOmitsFormattingURLsAndMediaTokens() {
        #expect(ReaderSpeech.text(for: article) == "Title\n\nHeading\n\nHello world.")
        #expect(ReaderSpeech.text(for: .init(title: "", author: "", date: "", markdown: "")) == "")
    }
    @Test func playbackPausesResumesStopsAndIgnoresOldCompletion() {
        let engine = SpeechFixture(), speech = ReaderSpeech(engine: engine)
        speech.toggle(article: article)
        #expect(speech.state == .speaking && engine.text == ReaderSpeech.text(for: article))
        let old = engine.completion
        speech.toggle(article: article); #expect(speech.state == .paused)
        speech.toggle(article: article); #expect(speech.state == .speaking)
        speech.stop(); #expect(speech.state == .idle && engine.stops == 1)
        speech.toggle(article: article); old?(); #expect(speech.state == .speaking)
        engine.completion?(); #expect(speech.state == .idle)
    }
    @Test func voiceAndSpeedArePassedToTheEngineOnStart() {
        let engine = SpeechFixture(), speech = ReaderSpeech(engine: engine)
        speech.toggle(article: article, options: .init(voiceID: "fixture", speed: 1.2))
        #expect(engine.options.voiceID == "fixture" && engine.options.speed == 1.2)
        #expect(ReaderSpeechOptions(speed: .nan).rate == ReaderSpeechOptions().rate)
        #expect(ReaderSpeechOptions(speed: 100).rate == ReaderSpeechOptions(speed: 1.5).rate)
        speech.stop()
    }
    @Test func anotherReaderStopsPreviousSpeechAndRejectedPauseKeepsState() {
        let firstEngine = SpeechFixture(), secondEngine = SpeechFixture()
        let first = ReaderSpeech(engine: firstEngine), second = ReaderSpeech(engine: secondEngine)
        first.toggle(article: article)
        firstEngine.accept = false
        first.toggle(article: article); #expect(first.state == .speaking)
        second.toggle(article: article)
        #expect(first.state == .idle && firstEngine.stops == 1)
        #expect(second.state == .speaking)
        second.stop()
    }
}
@MainActor private final class SpeechFixture: ReaderSpeechEngine {
    var options = ReaderSpeechOptions()
    var text = "", stops = 0, accept = true
    var completion: (@MainActor () -> Void)?
    func speak(_ text: String, options: ReaderSpeechOptions, completion: @escaping @MainActor () -> Void) { self.text = text; self.options = options; self.completion = completion }
    func pause() -> Bool { accept }
    func resume() -> Bool { accept }
    func stop() { stops += 1 }
}
