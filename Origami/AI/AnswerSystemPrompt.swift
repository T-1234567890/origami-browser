import Foundation

enum AnswerSystemPrompt {
    static func make(mode: AskMode, action: AIAction, visuals: Bool) -> String {
        let base = Bundle.main.url(forResource: "AnswerSystemPrompt", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let visualPolicy = visuals ? """
        GENERATED VISUALS ON
        Optional generated_visual blocks are permitted only when they materially improve understanding: an unusual diagram, a self-contained educational demonstration, or an interactive concept that native blocks cannot explain as effectively. Prefer native paragraphs, comparisons, tables, timelines, and steps whenever sufficient. Enabling visuals does not require creating one. Never put essential conclusions only inside a visual. Each visual may disappear silently; the summary and native blocks must remain complete without it.
        Interactive visuals may use sliders, buttons, local state, canvas drawing, and bounded event handlers to explain the concept. Keep each visual compact (aim for under 6 KB combined code) and put native explanation blocks before it. Keep title, html, css, and javascript separate. HTML must be well-formed XHTML fragments using only div, span, p, h1-h3, ul, ol, li, strong, em, b, i, br, button, label, input, canvas, section, article, table, thead, tbody, tr, th, and td. Close void elements explicitly. Input is only for local controls. Allowed HTML attributes are id, class, type, min, max, step, value, width, height, role, aria-label, aria-hidden, for, and tabindex. Style elements through the separate CSS field, not inline style attributes. No script tags, inline event attributes, forms, links, images, embeds, iframes, SVG, external resources, URL-valued attributes, CSS imports or CSS URLs. Attach event listeners from the separate JavaScript field. Use at most 24 KB HTML, 12 KB CSS, and 24 KB JavaScript. Keep height between 40 and 480 CSS pixels. Do not create endless loops or recursive workloads. Computation must finish promptly; interactions must be bounded and local. No networking, storage, workers, WebAssembly, native messages, popup windows, local APIs, filesystem, shell, browser credentials, or Keychain. Do not use eval or dynamically compiled code. Generated JavaScript may manipulate only its own visual document and has no Origami bridge.
        """ : """
        Return only the native block types declared in the output schema. Requested code examples are inert code blocks.
        """
        let schemaText = (try? JSONSerialization.data(withJSONObject: AnswerProtocol.schema(visuals: visuals), options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return base + "\nACTIVE MODE: \(mode.rawValue). ACTIVE TASK: \(action.rawValue).\n" + visualPolicy + "\nEXACT OUTPUT JSON SCHEMA:\n" + schemaText
    }
}
