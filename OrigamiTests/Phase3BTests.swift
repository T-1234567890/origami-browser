import Testing
import Foundation
import WebKit
@testable import Origami

@MainActor struct Phase3BTests {
    @Test func appearancePersistsAndMigratesFrame() throws {
        let suite = "Origami.AppearanceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = Personalization(defaults: defaults)
        #expect(initial.hex == "55D4B3" && initial.frame == "Subtle" && initial.mode == "System")
        #expect(initial.tabHeight == 26 && initial.favorites)
        initial.hex = "3478F6"; initial.mode = "Dark"; initial.density = "Comfortable"; initial.frame = "Accent"
        let restored = Personalization(defaults: defaults)
        #expect(restored.hex == "3478F6" && restored.mode == "Dark" && restored.frame == "Accent" && restored.tabHeight == 32)
        defaults.removeObject(forKey: "appearance.frame"); defaults.set(false, forKey: "browser.contentFrame")
        #expect(Personalization(defaults: defaults).frame == "Off")
    }
    @Test func scriptsStayProfileScoped() throws {
        let db = try DatabaseManager(); let profiles = ProfileRepository(db)
        let personal = try profiles.ensureDefault(); let work = try profiles.create(name: "Work")
        let repository = PowerRepository(db)
        var script = UserScript(name: "Example", source: "document.title='changed'", patterns: "example.com")
        try repository.save(script, profile: personal.id)
        #expect(try repository.scripts(work.id).isEmpty)
        script.enabled = true; try repository.save(script, profile: personal.id)
        #expect(try repository.scripts(personal.id).first?.enabled == true)
        try repository.remove(script, profile: work.id)
        #expect(try repository.scripts(personal.id).count == 1)
        try repository.remove(script, profile: personal.id)
        #expect(try repository.scripts(personal.id).isEmpty)
    }
    @Test func patternsExcludeNativePagesAndOtherHosts() {
        #expect(UserScript.matches("*.example.com", url: URL(string: "https://www.example.com/a")!))
        #expect(UserScript.matches("https://example.com/articles/*", url: URL(string: "https://example.com/articles/one")!))
        #expect(!UserScript.matches("example.com", url: URL(string: "https://example.com.evil.test")!))
        #expect(!UserScript.matches("*", url: URL(string: "origami://settings")!))
        #expect(!UserScript.matches("*", url: URL(string: "file:///tmp/test")!))
    }
    @Test(.timeLimit(.minutes(1))) func scriptsExecuteInIsolatedWorldAndDisabledScriptsDoNotRun() async throws {
        let page = TabPage(); defer { page.dispose() }
        let script = UserScript(name: "Isolated", source: "window.scriptSecret=42; document.body.dataset.script='yes';", patterns: "https://example.com/*", enabled: true)
        let disabled = UserScript(name: "Disabled", source: "document.body.dataset.disabled='yes';", patterns: "*", enabled: false)
        ScriptRuntime.install([script, disabled], controller: page.webView.configuration.userContentController)
        page.webView.loadHTMLString("<title>Isolation</title><body>Example</body>", baseURL: URL(string: "https://example.com/article"))
        try await loaded(page, title: "Isolation")
        let state = try await page.webView.callAsyncJavaScript("return [document.body.dataset.script || '', document.body.dataset.disabled || '', typeof window.scriptSecret];", arguments: [:], in: nil, contentWorld: .page) as? [String]
        #expect(state == ["yes", "", "undefined"])
        let native = try await page.webView.callAsyncJavaScript("return typeof window.webkit?.messageHandlers?.origamiMedia;", arguments: [:], in: nil, contentWorld: .world(name: "Origami.UserScript." + script.id)) as? String
        #expect(native == "undefined")
        ScriptRuntime.install([], controller: page.webView.configuration.userContentController)
        #expect(!page.webView.configuration.userContentController.userScripts.contains { $0.source.hasPrefix("/* Origami user script */") })
        #expect(!page.webView.configuration.userContentController.userScripts.isEmpty)
    }
    private func loaded(_ page: TabPage, title: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != title {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
