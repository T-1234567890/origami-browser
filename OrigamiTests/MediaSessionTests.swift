import Foundation
import WebKit
import Testing
@testable import Origami

@MainActor
struct MediaSessionTests {
    @Test func snapshotValidationNeverInventsProgressOrCapabilities() {
        let live = TabMediaState(snapshot: ["id": "live", "phase": "playing", "live": true, "duration": 400.0, "currentTime": 50.0, "canSeek": true])
        #expect(live.isLive && live.isPlayingMedia)
        #expect(live.duration == nil && !live.canSeek)
        #expect(!live.hasNext && !live.hasPrevious)
        let unknown = TabMediaState(snapshot: ["id": "unknown", "phase": "paused", "duration": Double.nan, "currentTime": Double.infinity])
        #expect(unknown.isRelevant && !unknown.isPlayingMedia)
        #expect(unknown.duration == nil && unknown.currentTime == nil)
        #expect(!TabMediaState(snapshot: ["title": "Metadata only"]).isRelevant)
        #expect(!TabMediaState(snapshot: ["id": "ended", "phase": "inactive"]).isRelevant)
        #expect(MediaTime.label(102) == "1:42")
        #expect(MediaTime.label(.infinity) == "—")
    }

    @Test(.timeLimit(.minutes(1)))
    func playbackEventsDrivePauseResumeAndEnd() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        #expect(!page.mediaState.isRelevant)
        _ = try await page.webView.callAsyncJavaScript(Self.startMedia, arguments: [:], in: nil, contentWorld: .page)
        try await wait { page.mediaState.isPlayingMedia }
        #expect(page.mediaState.title == "Media fixture")
        #expect(page.mediaState.duration == 5)
        #expect(!page.mediaState.isLive)
        #expect(!page.mediaState.hasNext && !page.mediaState.hasPrevious)
        #expect(await page.controlMedia("pause"))
        try await wait { page.mediaState.phase == .paused }
        #expect(page.mediaState.isRelevant)
        #expect(await page.controlMedia("play"))
        try await wait { page.mediaState.isPlayingMedia }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('audio').currentTime=5")
        try await wait { !page.mediaState.isRelevant }
    }

    @Test(.timeLimit(.minutes(1)))
    func metadataAndUnplayedElementsDoNotCreateSessions() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        _ = try await page.webView.evaluateJavaScript("navigator.mediaSession.metadata = new MediaMetadata({title:'Not playing'}); navigator.mediaSession.playbackState='playing'")
        let state = await MediaStateService().sample(page.webView)
        #expect(!state.isRelevant)
        #expect(!page.mediaState.isPlayingMedia)
        #expect(!(await page.controlMedia("play")))
    }

    @Test(.timeLimit(.minutes(1)))
    func transportUsesRegisteredMediaHandlersAndIgnoresMutedPreviews() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        _ = try await page.webView.callAsyncJavaScript(Self.startMedia, arguments: [:], in: nil, contentWorld: .page)
        try await wait { page.mediaState.isRelevant }
        _ = try await page.webView.evaluateJavaScript("window.nextCount=0; navigator.mediaSession.setActionHandler('nexttrack',()=>window.nextCount++)")
        try await wait { page.mediaState.hasNext }
        let url = page.currentURL
        #expect(await page.controlMedia("nexttrack"))
        #expect(try await page.webView.evaluateJavaScript("window.nextCount") as? Int == 1)
        #expect(page.currentURL == url)
        #expect(!(await page.controlMedia("previoustrack")))
        _ = try await page.webView.evaluateJavaScript("document.querySelector('audio').loop=true")
        try await wait { !page.mediaState.isRelevant }
    }

    @Test(.timeLimit(.minutes(1)))
    func seekingLiveAndStalePauseStatesStayAccurate() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        _ = try await page.webView.callAsyncJavaScript(Self.startMedia, arguments: [:], in: nil, contentWorld: .page)
        try await wait { page.mediaState.canSeek }
        #expect(await page.controlMedia("seekto", time: 2))
        try await wait { page.mediaState.currentTime == 2 }
        #expect(!(await page.controlMedia("seekto", time: 99)))
        _ = try await page.webView.evaluateJavaScript("window.fixturePlayback.duration=Infinity;document.querySelector('audio').dispatchEvent(new Event('durationchange'))")
        try await wait { page.mediaState.isLive }
        #expect(page.mediaState.duration == nil && !page.mediaState.canSeek)
        #expect(await page.controlMedia("pause"))
        try await wait { page.mediaState.phase == .paused }
        _ = try await page.webView.evaluateJavaScript("const originalNow=Date.now;Date.now=()=>originalNow()+120001;true")
        try await wait { !page.mediaState.isRelevant }
    }

    @Test(.timeLimit(.minutes(1)))
    func embeddedPlayerCommandsTargetTheReportingFrame() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        _ = try await page.webView.callAsyncJavaScript("""
            const frame=document.createElement('iframe');
            frame.srcdoc='<title>Embedded media</title><audio muted></audio>';
            const loaded=new Promise(resolve=>frame.onload=resolve);
            document.body.append(frame); await loaded;
            return await frame.contentWindow.eval('(async()=>{' + fixture + '})()');
            """, arguments: ["fixture": Self.startMedia], in: nil, contentWorld: .page)
        try await wait { page.mediaState.isPlayingMedia }
        #expect(page.mediaState.title == "Embedded media")
        #expect(await page.controlMedia("pause"))
        try await wait { page.mediaState.phase == .paused }
        #expect(try await page.webView.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('audio').paused") as? Bool == true)
        _ = try await page.webView.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('audio').remove()")
        try await wait { !page.mediaState.isRelevant }
    }

    @Test(.timeLimit(.minutes(1)))
    func detachedAudioAppearsOnlyAfterPlayback() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        _ = try await page.webView.evaluateJavaScript("window.detachedAudio=new Audio();true")
        #expect(!page.mediaState.isRelevant)
        _ = try await page.webView.callAsyncJavaScript(Self.startMedia, arguments: [:], in: nil, contentWorld: .page)
        try await wait { page.mediaState.isPlayingMedia }
        #expect(await page.controlMedia("pause"))
        try await wait { page.mediaState.phase == .paused }
    }

    @Test func internalDestinationsSuspendHiddenPlaybackAndSuppressLateReports() async throws {
        let page = makePage()
        defer { page.dispose() }
        try await ready(page)
        let retained = page.webView
        _ = try await page.webView.callAsyncJavaScript(Self.startMedia, arguments: [:], in: nil, contentWorld: .page)
        try await wait { page.mediaState.isPlayingMedia }
        page.load(InternalPage.history.url)
        #expect(page.mediaPlaybackSuspended)
        #expect(!page.mediaState.isRelevant)
        // A retained document can still report events; native destinations must ignore them.
        _ = try await page.webView.evaluateJavaScript("document.querySelector('audio').dispatchEvent(new Event('playing')); true")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!page.mediaState.isRelevant)
        #expect(!(await page.controlMedia("play")))
        page.goBack()
        #expect(!page.mediaPlaybackSuspended)
        #expect(page.webView === retained)
        page.goForward()
        #expect(page.nativePage == .history && page.mediaPlaybackSuspended)
    }

    private func makePage() -> TabPage {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let page = TabPage(configuration: configuration)
        let html = "<title>Media fixture</title><audio muted></audio>"
        page.load(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!)
        return page
    }
    private func ready(_ page: TabPage) async throws {
        try await wait { page.webView.title == "Media fixture" && !page.isLoading }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
    // Simulate decoder state/events in a real WebKit document. Offscreen WebKit does
    // not reliably start AVFoundation playback; these tests do not claim codec/site validation.
    private static let startMedia = """
        const element = window.detachedAudio || document.querySelector('audio');
        const playback = {paused:true,ended:false,time:0,duration:5}; window.fixturePlayback=playback;
        Object.defineProperties(element, {
          paused: {get:()=>playback.paused}, ended: {get:()=>playback.ended},
          readyState: {get:()=>4}, currentSrc: {get:()=> 'https://example.com/track.wav'},
          duration: {get:()=>playback.duration}, seekable: {get:()=>({length:1,start:()=>0,end:()=>5})},
          currentTime: {get:()=>playback.time,set:value=>{
            playback.time=value; element.dispatchEvent(new Event('seeked'));
            if(value>=5){playback.ended=true;playback.paused=true;element.dispatchEvent(new Event('ended'))}
          }}
        });
        element.muted=true;
        element.play=async()=>{playback.paused=false;element.dispatchEvent(new Event('playing'))};
        element.pause=()=>{playback.paused=true;element.dispatchEvent(new Event('pause'))};
        await element.play(); return true;
        """
}
