import Foundation
import Testing
import WebKit
@testable import Origami

@MainActor struct ExperienceCleanupTests {
    @Test func standardStylesAreBundledAndFormatEditedMetadata() throws {
        let citation = PageCitation(title: "A useful article", author: "Smith, Jane", publisher: "Example", published: "2024-03-04", url: "https://example.com/article")
        #expect(PageCitation.formats == ["APA", "MLA", "Chicago"])
        for style in PageCitation.formats {
            let text = try #require(CitationProcessor.render(citation, style: style))
            #expect(text.contains("2024") && text.contains("Smith") && text.contains("https://example.com/article"))
        }
    }
    @Test(.timeLimit(.minutes(1))) func readerRejectsSearchAndPreservesArticleLinks() async throws {
        let page = TabPage(); defer { page.dispose() }
        let paragraph = String(repeating: "A detailed explanation of this subject provides useful evidence and context for readers. ", count: 5)
        let body = "<article><h1>Useful article</h1>" + String(repeating: "<p>\(paragraph)<a href='/source'>Original source</a></p>", count: 5) + "</article>"
        for (host, expected) in [("example.com", true), ("www.google.com", false)] {
            page.webView.loadHTMLString("<title>\(host)</title>" + body, baseURL: URL(string: "https://\(host)/search"))
            let deadline = Date().addingTimeInterval(15)
            while page.webView.isLoading || page.webView.title != host {
                guard Date() < deadline else { throw RepositoryError.invalidInput }
                try await Task.sleep(for: .milliseconds(50))
            }
            page.article = nil
            await page.discoverDocuments()
            #expect((page.article != nil) == expected)
            if expected { #expect(page.article?.markdown.contains("[Original source](https://example.com/source)") == true) }
        }
    }
    @Test(.timeLimit(.minutes(1))) func readerFindsDelayedShortBlogAndRejectsLinkIndex() async throws {
        let page = TabPage(); defer { page.dispose() }
        let paragraph = String(repeating: "This post explains a practical design decision, including the reasons behind it and the results of testing it. ", count: 3)
        let article = "<article><h1>A short blog post</h1><p>\(paragraph)</p><p>\(paragraph) <a href='/evidence'>Evidence</a></p></article>"
        let menu = "<nav>" + String(repeating: "<a href='/archive'>Browse the extensive archive of articles and categories</a>", count: 50) + "</nav>"
        page.webView.loadHTMLString("<title>Delayed blog</title>\(menu)<main id='content'></main>", baseURL: URL(string: "https://example.com/blog"))
        var deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != "Delayed blog" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        page.scheduleDocumentDiscovery()
        try await Task.sleep(for: .milliseconds(250))
        #expect(page.article == nil)
        _ = try await page.webView.callAsyncJavaScript("document.getElementById('content').innerHTML = html", arguments: ["html": article], in: nil, contentWorld: .page)
        deadline = Date().addingTimeInterval(10)
        while page.article == nil {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(page.article?.markdown.contains("[Evidence](https://example.com/evidence)") == true)
        #expect(page.article?.markdown.contains("extensive archive") == false)

        let index = (0..<10).map { "<article><h2><a href='/post/\($0)'>Post \($0)</a></h2><p><a href='/post/\($0)'>\(paragraph)</a></p></article>" }.joined()
        page.webView.loadHTMLString("<title>Blog archive</title><main>\(index)</main>", baseURL: URL(string: "https://example.com/archive"))
        deadline = Date().addingTimeInterval(15)
        while page.webView.isLoading || page.webView.title != "Blog archive" {
            guard Date() < deadline else { throw RepositoryError.invalidInput }
            try await Task.sleep(for: .milliseconds(50))
        }
        await page.discoverDocuments()
        #expect(page.article == nil)
    }

}
