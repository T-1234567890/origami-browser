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
      function snapshot() {
        const element = candidates()[0];
        if (!element) return null;
        const state = record(element), metadata = session?.metadata;
        const duration = Number.isFinite(element.duration) && element.duration > 0 ? element.duration : null;
        const currentTime = Number.isFinite(element.currentTime) && element.currentTime >= 0 ? element.currentTime : null;
        const seekable = element.seekable;
        const canSeek = duration !== null && seekable.length === 1 && seekable.start(0) <= 0.1 && seekable.end(0) >= duration - 0.5;
        const artwork = metadata?.artwork?.find(item => /^https?:/.test(item.src))?.src || (element.poster || '');
        return {id: state.id, phase: element.paused ? 'paused' : 'playing', live: element.duration === Infinity,
          title: String(metadata?.title || document.title || '').slice(0,512), source: location.hostname,
          artwork: String(artwork).slice(0,4096), currentTime, duration, canSeek,
          previous: handlers.has('previoustrack'), next: handlers.has('nexttrack'), muted: element.muted,
          activityAt: state.activityAt};
      }
      function report() {
        const media = snapshot();
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
