import SwiftUI
import AVFoundation

struct ReaderSpeechPopover: View {
    let speech: ReaderSpeech
    let article: ReaderArticle
    @AppStorage("reader.speech.voice") private var voice = ""
    @AppStorage("reader.speech.speed") private var speed = 1.0
    @State private var voices: [AVSpeechSynthesisVoice] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Read Aloud").font(.headline)
            Picker("Voice", selection: $voice) {
                Text("System Default").tag("")
                ForEach(voices, id: \.identifier) { Text("\($0.name) (\($0.language))").tag($0.identifier) }
            }
            HStack {
                Text("Speed")
                Slider(value: $speed, in: 0.5...1.5, step: 0.1).accessibilityLabel("Reading speed")
                Text(speed, format: .number.precision(.fractionLength(1))).monospacedDigit()
            }
            if speech.state != .idle { Text("Voice and speed changes apply the next time you start reading.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button {
                    speech.toggle(article: article, options: ReaderSpeechOptions(voiceID: voice, speed: speed))
                } label: {
                    Label(speech.state == .speaking ? "Pause" : speech.state == .paused ? "Resume" : "Read Aloud", systemImage: speech.state == .speaking ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderedProminent)
                Button("Stop", systemImage: "stop.fill") { speech.stop() }
                    .disabled(speech.state == .idle)
            }
        }.padding(16).frame(width: 300)
            .task {
                voices = AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
                if !voice.isEmpty, !voices.contains(where: { $0.identifier == voice }) { voice = "" }
            }
    }
}
