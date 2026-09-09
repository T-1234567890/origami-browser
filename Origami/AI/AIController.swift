import Foundation
import Observation
import WebKit

@MainActor @Observable final class AIController {
    let repository: AISearchRepository
    let isPrivate: Bool
    var events: [UUID: AISearchEvent] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryInputs: [UUID: AIRequest] = [:]
    @ObservationIgnored private let client: any AIAnswerClient
    init(database: DatabaseManager, isPrivate: Bool, client: (any AIAnswerClient)? = nil) { repository = AISearchRepository(database); self.isPrivate = isPrivate; self.client = FallbackAIClient(base: client ?? NativeAIClient(), settings: .shared) }
    func restore(tab: UUID, profile: UUID) {
        guard !isPrivate, events[tab] == nil else { return }
        if var event = try? repository.event(tab: tab, profile: profile) {
            if event.status != "Complete" { event.status = "Interrupted — submit again to retry." }
            events[tab] = event
        }
    }
    func start(_ input: AIRequest, tab: UUID, profile: UUID) {
        var input = input; input.isPrivate = isPrivate; input.generatedVisuals = input.action != .credibility && AISettings.shared.generatedVisuals
        cancel(tab)
        let provider = AISettings.shared.provider
        var event = AISearchEvent(query: input.query, mode: input.mode, action: input.action, provider: provider, model: input.model)
        event.profileID = profile
        event.status = "Requesting answer"
        if let old = events[tab] { retryInputs.removeValue(forKey: old.id) }
        events[tab] = event
        retryInputs[event.id] = input
        let eventID = event.id
        tasks[tab] = Task { [weak self] in
            guard let self else { return }
            defer { if events[tab]?.id == eventID { tasks.removeValue(forKey: tab) } }
            do {
                let result = try await client.stream(provider: provider, input: input) { [weak self] partial in
                    guard let self, var current = events[tab], current.id == eventID else { return }
                    if (try? AnswerProtocol.apply(partial, to: &current, input: input, isFinal: false)) != nil { current.status = "Requesting answer"; events[tab] = current }
                }
                try Task.checkCancellation()
                guard events[tab]?.id == eventID else { return }
                try AnswerProtocol.apply(result, to: &event, input: input)
                retryInputs.removeValue(forKey: eventID)
                events[tab] = event
                if !isPrivate { try repository.save(event, profile: profile, tab: tab) }
            } catch {
                guard events[tab]?.id == eventID else { return }
                event.answerV1 = nil
                event.status = Task.isCancelled ? "Cancelled" : (error as? AIError)?.localizedDescription ?? "The request could not finish. Check your connection and provider settings."
                event.needsSetup = (error as? AIError)?.requiresSetup
                if event.needsSetup == true && AISettings.shared.provider == provider { AISettings.shared.setVerified(false) }
                events[tab] = event
            }
        }
    }
    func followUp(_ query: String, tab: UUID, profile: UUID, model: String, mode: AskMode? = nil, versions: [AISearchEvent]? = nil) {
        guard let root = events[tab], root.status == "Complete", (root.explorations?.count ?? 0) < 20 else { return }
        cancel(tab)
        let mode = mode ?? root.mode
        let provider = AISettings.shared.provider
        var answer = AISearchEvent(query: String(query.prefix(12000)), mode: mode, action: .web, provider: provider, model: model)
        answer.versions = versions
        answer.profileID = profile; answer.status = "Requesting answer"
        var updated = root; updated.explorations = (root.explorations ?? []) + [answer]; events[tab] = updated
        var input = AIRequest(query: answer.query, mode: mode, action: .web, contexts: [], model: model, priorExploration: Self.followUpContext(root))
        input.generatedVisuals = AISettings.shared.generatedVisuals
        input.isPrivate = isPrivate
        let answerID = answer.id
        tasks[tab] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.stream(provider: provider, input: input) { [weak self] partial in
                    guard let self, var current = events[tab], current.id == root.id, current.explorations?.last?.id == answerID else { return }
                    let index = (current.explorations?.count ?? 1) - 1
                    if var preview = current.explorations?[index], (try? AnswerProtocol.apply(partial, to: &preview, input: input, isFinal: false)) != nil { preview.status = "Requesting answer"; current.explorations?[index] = preview; events[tab] = current }
                }
                try Task.checkCancellation()
                try AnswerProtocol.apply(result, to: &answer, input: input)
            } catch {
                answer.answerV1 = nil
                answer.status = Task.isCancelled ? "Cancelled" : (error as? AIError)?.localizedDescription ?? "The follow-up could not finish."
                answer.needsSetup = (error as? AIError)?.requiresSetup
                if answer.needsSetup == true && AISettings.shared.provider == provider { AISettings.shared.setVerified(false) }
            }
            guard var current = events[tab], current.id == root.id, current.explorations?.last?.id == answerID else { return }
            let index = (current.explorations?.count ?? 1) - 1
            current.explorations?[index] = answer
            events[tab] = current; tasks.removeValue(forKey: tab)
            if !isPrivate { try? repository.save(current, profile: profile, tab: tab) }
        }
    }
    static func followUpContext(_ root: AISearchEvent) -> String {
        let recent = Array((root.explorations ?? []).filter { $0.status == "Complete" }.suffix(3))
        return ([root] + recent).map { event in
            let text = event.answerV1?.plainText ?? event.markdown ?? event.blocks.map(\.text).joined(separator: "\n")
            let urls = event.answerV1?.sources.map(\.url) ?? event.sources.map(\.url)
            return "Earlier query: " + String(event.query.prefix(1000)) + "\nEarlier answer (excerpt): " + String(text.prefix(4000)) + "\nEarlier source URLs (unverified): " + String(urls.prefix(6).joined(separator: ", ").prefix(700))
        }.joined(separator: "\n\n")
    }
    func editFollowUp(_ id: UUID, query: String, tab: UUID, profile: UUID, model: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, var root = events[tab], root.status == "Complete",
              root.explorations?.contains(where: { $0.status == "Requesting answer" }) != true,
              let index = root.explorations?.firstIndex(where: { $0.id == id }),
              var previous = root.explorations?[index], (previous.versions?.count ?? 0) < 19 else { return }
        var versions = previous.versions ?? []
        previous.versions = nil
        previous.explorations = Array((root.explorations ?? []).dropFirst(index + 1))
        versions.append(previous)
        root.explorations = Array((root.explorations ?? []).prefix(index)); events[tab] = root
        followUp(query, tab: tab, profile: profile, model: model, mode: previous.mode, versions: versions)
    }
    func selectVersion(_ versionID: UUID, followUp id: UUID, tab: UUID, profile: UUID) throws {
        guard var root = events[tab], root.explorations?.contains(where: { $0.status == "Requesting answer" }) != true,
              let index = root.explorations?.firstIndex(where: { $0.id == id }), var current = root.explorations?[index],
              var versions = current.versions, let selected = versions.firstIndex(where: { $0.id == versionID }) else { return }
        var version = versions.remove(at: selected)
        current.versions = nil; current.explorations = Array((root.explorations ?? []).dropFirst(index + 1))
        versions.append(current)
        let continuation = version.explorations ?? []
        version.explorations = nil; version.versions = versions
        root.explorations = Array((root.explorations ?? []).prefix(index)) + [version] + continuation
        if !isPrivate { try repository.save(root, profile: profile, tab: tab) }
        events[tab] = root
    }
    func deleteHistory(_ ids: Set<UUID>, profile: UUID) throws {
        if !isPrivate { try repository.delete(ids, profile: profile) }
        for (tab, event) in events where ids.contains(event.id) && event.profileID == profile { release(tab) }
        NotificationCenter.default.post(name: .origamiHistoryChanged, object: nil)
    }
    func discardExpiredHistory(_ ids: Set<UUID>) {
        for (tab, event) in events where ids.contains(event.id) { release(tab) }
    }
    func deleteHistory(_ id: UUID, profile: UUID) throws {
        if !isPrivate { try repository.delete(id, profile: profile) }
        for (tab, event) in events where event.id == id && event.profileID == profile { release(tab) }
    }
    func canRetry(_ id: UUID, tab: UUID) -> Bool {
        guard let root = events[tab] else { return false }
        let target = root.id == id ? root : root.explorations?.last
        guard let target, target.id == id, target.status != "Complete", target.status != "Requesting answer" else { return false }
        return root.id != id || retryInputs[id] != nil || target.action == .web
    }
    func retry(_ id: UUID, tab: UUID, profile: UUID) {
        guard canRetry(id, tab: tab), let root = events[tab] else { return }
        if root.id == id {
            let input = retryInputs[id] ?? AIRequest(query: root.query, mode: root.mode, action: root.action, contexts: [], model: root.model)
            start(input, tab: tab, profile: profile)
        } else if let answer = root.explorations?.last {
            var updated = root; updated.explorations?.removeLast(); events[tab] = updated
            followUp(answer.query, tab: tab, profile: profile, model: answer.model, mode: answer.mode, versions: answer.versions)
        }
    }
    func cancel(_ tab: UUID) { tasks.removeValue(forKey: tab)?.cancel() }
    func release(_ tab: UUID) { cancel(tab); if let id = events[tab]?.id { retryInputs.removeValue(forKey: id) }; events.removeValue(forKey: tab) }
    func clear(_ tab: UUID) { release(tab); if !isPrivate { try? repository.unlink(tab: tab) } }
    func clearHistory(profile: UUID, since: Date) throws {
        if !isPrivate { try repository.clear(profile: profile, since: since) }
        for (tab, event) in events where event.profileID == profile && event.date >= since { release(tab) }
    }
    func stop() { for tab in Array(tasks.keys) { cancel(tab) }; if isPrivate { events.removeAll(); retryInputs.removeAll() } }
    static func context(_ page: TabPage, selection: Bool = false) async throws -> AIPageContext {
        guard page.nativePage == nil, let url = page.currentURL, AISource.safeURL(url.absoluteString) != nil else { throw AIError.noPage }
        let text: String
        if selection {
            text = try await page.webView.callAsyncJavaScript("return window.getSelection()?.toString().slice(0,20000) || '';", arguments: [:], in: nil, contentWorld: .world(name: "Origami.AIExtraction")) as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.noSelection }
        } else if let article = page.article { text = String(article.exportMarkdown.prefix(30000)) }
        else {
            text = try await page.webView.callAsyncJavaScript("const root=document.querySelector('article,main') || document.body; const clone=root.cloneNode(true); clone.querySelectorAll('input,textarea,select,script,style,[contenteditable],[hidden],[aria-hidden=true],nav,footer').forEach(e=>e.remove()); return (clone.textContent || '').slice(0,30000);", arguments: [:], in: nil, contentWorld: .world(name: "Origami.AIExtraction")) as? String ?? ""
        }
        guard page.currentURL == url else { throw AIError.noPage }
        var clean = URLComponents(url: url, resolvingAgainstBaseURL: false); clean?.user = nil; clean?.password = nil; let items = clean?.queryItems?.filter { $0.name.range(of: "token|key|auth|pass|secret|session|signature", options: [.regularExpression, .caseInsensitive]) == nil }; clean?.queryItems = items; clean?.fragment = nil
        return AIPageContext(title: page.pageTitle ?? url.host ?? "Page", url: clean?.url?.absoluteString ?? url.absoluteString, text: text)
    }
}
