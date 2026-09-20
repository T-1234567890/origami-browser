import Foundation

/// Unprivileged, document-local media observation. Reports never authorize browser actions.
enum MediaSessionScript {
    static let source = #"""
    (() => {
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
      const hex = [...bytes].map(value => value.toString(16).padStart(2,'0')).join('');
      const documentID = [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
      const records = new WeakMap(), handlers = new Map(), tracked = new Set(), observed = new WeakSet(), handled = new WeakSet();
      let sequence = 0, timer = null, reported = false;
      let publishedLive = false;
      const pauseLifetime = 120000;
      function record(element) {
        if (!records.has(element)) records.set(element, {id: documentID + ':' + (++sequence), played: false, activityAt: 0, pausedAt: 0, wasConnected: element.isConnected});
        return records.get(element);
      }
      function candidates() {
        return [...tracked].filter(element => {
          const state = record(element);
          state.wasConnected ||= element.isConnected;
          if (state.wasConnected && !element.isConnected || element.error || element.ended || !element.currentSrc || element.readyState < 2) return false;
          if (Number.isFinite(element.duration) && element.duration > 0 && element.currentTime >= element.duration) return false;
          if (!state.played) return false;
          // Muted looping previews are not a meaningful player unless started by the user.
          if (element.muted && element.loop && !state.userStarted) return false;
          return !element.paused || state.pausedAt > 0 && Date.now() - state.pausedAt < pauseLifetime;
        }).sort((a,b) => Number(a.paused) - Number(b.paused) || record(b).activityAt - record(a).activityAt);
      }
      let lastGesture = 0;
      for (const name of ['pointerdown','keydown']) addEventListener(name, event => { if(event.isTrusted) lastGesture = Date.now(); }, true);
      const session = navigator.mediaSession;
      if (session) {
        const original = session.setActionHandler.bind(session);
        try {
          session.setActionHandler = function(action, handler) {
            original(action, handler);
            if (handler) handlers.set(action, handler); else handlers.delete(action);
          };
        } catch (_) { /* Unsupported action interception leaves Previous/Next unavailable. */ }
      }
      function artworkURL(items) {
        const choices = [...(items || [])].slice(0,32).flatMap(item => {
          let url; try { url = new URL(item.src, document.baseURI); } catch (_) { return []; }
          if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return [];
          const sizes = String(item.sizes || '').split(/\s+/).map(size => /^(\d+)x(\d+)$/.exec(size))
            .filter(Boolean).map(size => Math.max(Number(size[1]), Number(size[2]))).filter(size => size > 0);
          const suitable = sizes.filter(size => size <= 2048);
          if (sizes.length && !suitable.length) return [];
          const size = suitable.sort((a,b) => Math.abs(a-320)-Math.abs(b-320))[0];
          const score = size ? (size >= 224 ? Math.abs(size-320) : 1000-size) : 900;
          return [{url:url.href, score}];
        });
        return choices.sort((a,b)=>a.score-b.score)[0]?.url || '';
      }
      function youtubeIsLive(element) {
        if (!/(^|\.)youtube\.com$/.test(location.hostname) || element.tagName !== 'VIDEO') return false;
        const player = element.closest('.html5-video-player');
        if (!player) return false;
        if (player.classList.contains('ytp-live')) return true;
        // Current YouTube layouts expose a Live badge without the old ytp-live
        // class. VOD retains that node but hides it, so existence alone is unsafe.
        const badge = player.querySelector('.ytp-live-badge');
        if (!badge || !badge.getClientRects().length) return false;
        for (let node = badge; node && node !== player; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (node.hidden || style.display === 'none' || style.visibility === 'hidden') return false;
        }
        return true;
      }
      function snapshot() {
        const element = candidates()[0];
        if (!element) return null;
        const state = record(element), metadata = session?.metadata;
        const range = element.seekable;
        const start = range.length === 1 ? range.start(0) : null;
        const end = range.length === 1 ? range.end(0) : null;
        // Finite DVR windows can still be live. Require both edges and the duration
        // to advance; an ordinary partially buffered VOD must not become "live".
        if (state.source !== element.currentSrc) { state.range = null; state.slidingLive = false; state.source = element.currentSrc; }
        if (state.range && [start,end,state.range.start,state.range.end].every(Number.isFinite) && start > state.range.start && end > state.range.end && element.duration > state.range.duration) state.slidingLive = true;
        state.range = {start, end, duration:element.duration};
        const youtubeLive = youtubeIsLive(element);
        const live = element.duration === Infinity || youtubeLive || state.slidingLive === true;
        const duration = !live && Number.isFinite(element.duration) && element.duration > 0 ? element.duration : null;
        const currentTime = Number.isFinite(element.currentTime) && element.currentTime >= 0 ? element.currentTime : null;
        const seekable = element.seekable;
        const canSeek = duration !== null && seekable.length === 1 && seekable.start(0) <= 0.1 && seekable.end(0) >= duration - 0.5;
        const artwork = artworkURL(metadata?.artwork) || (element.poster || '');
        return {id: state.id, phase: element.paused ? 'paused' : 'playing', live,
          title: String(metadata?.title || document.title || '').slice(0,512), source: location.hostname,
          artwork: String(artwork).slice(0,4096), currentTime, duration, canSeek,
          previous: handlers.has('previoustrack'), next: handlers.has('nexttrack'), muted: element.muted,
          activityAt: state.activityAt};
      }
      function report() {
        const media = snapshot();
        // Correct finite DVR timelines through the public Media Session API. WebKit
        // remains the only system Now Playing publisher; no parallel native session.
        if (session?.setPositionState && (media?.live || publishedLive)) {
          try {
            if (media?.live) {
              session.setPositionState({duration:Infinity, position:media.currentTime || 0, playbackRate:candidates()[0]?.playbackRate || 1});
            } else if (media?.duration && media.currentTime !== null) {
              session.setPositionState({duration:media.duration, position:media.currentTime, playbackRate:candidates()[0]?.playbackRate || 1});
            } else { session.setPositionState(); }
            publishedLive = media?.live === true;
          } catch (_) { /* Older WebKit may reject infinite duration; do not invent a finite one. */ }
        }
        for (const element of tracked) {
          const state = record(element);
          if (!state.played || element.ended || element.error || state.wasConnected && !element.isConnected ||
              element.paused && Date.now() - state.pausedAt >= pauseLifetime) tracked.delete(element);
        }
        if (media || reported) {
          try { window.webkit.messageHandlers.origamiMedia.postMessage({documentID, media}); } catch (_) {}
        }
        reported = !!media;
        if (media && timer === null) timer = setInterval(report, 1000);
        if (!media && timer !== null) { clearInterval(timer); timer = null; }
      }
      const events = ['playing','pause','ended','emptied','loadstart','error','durationchange','seeked','volumechange'];
      function handle(event) {
        const element = event.target;
        if (!(element instanceof HTMLMediaElement) || handled.has(event)) return;
        handled.add(event); observe(element); tracked.add(element);
        const state = record(element);
        if (event.type === 'playing' && !element.paused && !element.ended && element.readyState >= 2) {
          state.played = true; state.activityAt = Date.now(); state.pausedAt = 0;
          state.userStarted ||= Date.now() - lastGesture < 2000;
        }
        if (event.type === 'pause' && state.played) state.pausedAt = Date.now();
        if (['ended','emptied','loadstart','error'].includes(event.type)) { state.played = false; state.pausedAt = 0; }
        report();
      }
      function observe(element) {
        if (observed.has(element)) return;
        observed.add(element); record(element);
        for (const name of events) element.addEventListener(name, handle);
      }
      for (const name of events) addEventListener(name, handle, true);
      // Audio players often never attach their element to the DOM. Observe their
      // real events too, without counting construction or metadata as playback.
      const nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(...args) {
        observe(this); return Reflect.apply(nativePlay, this, args);
      };
      const NativeAudio = window.Audio;
      if (NativeAudio) window.Audio = new Proxy(NativeAudio, {construct(target,args,newTarget) {
        const element = Reflect.construct(target,args,newTarget); observe(element); return element;
      }});
      async function perform(action, id, time) {
        const element = candidates().find(element => record(element).id === id);
        if (!element) return false;
        if (action === 'play') {
          if (handlers.has('play')) await handlers.get('play')({action:'play'}); else await Promise.race([element.play(), new Promise((_,reject)=>setTimeout(()=>reject(new Error('Playback did not start')),3000))]);
        } else if (action === 'pause') {
          if (handlers.has('pause')) await handlers.get('pause')({action:'pause'}); else element.pause();
        } else if (action === 'previoustrack' || action === 'nexttrack') {
          const handler = handlers.get(action); if (!handler) return false;
          await handler({action});
        } else if (action === 'seekto') {
          if (!Number.isFinite(time) || !Number.isFinite(element.duration) || time < 0 || time > element.duration) return false;
          const ranges = element.seekable;
          if (ranges.length !== 1 || time < ranges.start(0) || time > ranges.end(0)) return false;
          element.currentTime = time;
        } else return false;
        report(); return true;
      }
      Object.defineProperty(window, '__origamiMedia', {value: Object.freeze({snapshot, perform}), configurable:false, writable:false});
      addEventListener('pageshow', report);
      addEventListener('pagehide', () => {
        if(timer !== null) clearInterval(timer);
        timer = null;
        try { window.webkit.messageHandlers.origamiMedia.postMessage({documentID, media:null}); } catch (_) {}
      });
    })();
    """#
}
