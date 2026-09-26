import WebKit

enum PasswordFillScript {
    static let world = WKContentWorld.world(name: "OrigamiPasswordFill")
    // No field values travel through the message handler. References live only in
    // this isolated world and are revalidated before a one-shot fill.
    static let source = #"""
    (() => {
      let target = null, serial = 0, scheduled = false;
      const visible = e => e instanceof HTMLInputElement && !e.disabled && !e.readOnly &&
        e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
      function fields(input) {
        if (location.protocol !== 'https:' || !visible(input) || !input.form) return null;
        const form = input.form;
        const action = new URL(form.action || location.href, location.href);
        if (action.origin !== location.origin || form.method.toLowerCase() !== 'post') return null;
        const all = Array.from(form.elements).filter(e => e instanceof HTMLInputElement);
        if (all.some(e => e.autocomplete.toLowerCase().split(/\s+/).includes('new-password'))) return null;
        const passwords = all.filter(e => e.type === 'password');
        if (passwords.length !== 1 || !visible(passwords[0])) return null;
        const users = all.filter(e => !e.autocomplete.toLowerCase().split(/\s+/).includes('one-time-code') && visible(e) && ['text','email'].includes(e.type) &&
          (e.autocomplete.toLowerCase().split(/\s+/).includes('username') ||
           /^(login|username|user|email)$/i.test(e.name) || /^(login|username|email)$/i.test(e.id)));
        if (users.length !== 1 || (input !== users[0] && input !== passwords[0])) return null;
        return {form, username:users[0], password:passwords[0], input, action:action.href};
      }
      function report() {
        const rect = target?.input.getBoundingClientRect();
        const onScreen = rect && target.input.isConnected && visible(target.input) &&
          rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
        window.webkit.messageHandlers.origamiPasswordFocus.postMessage({
          url:location.href, token:target?.token || '',
          x:onScreen ? Math.min(1, Math.max(0, rect.right / innerWidth)) : -1,
          y:onScreen ? rect.bottom / innerHeight : -1
        });
      }
      function schedule() {
        if (scheduled || !target) return;
        scheduled = true;
        setTimeout(() => { scheduled = false; report(); }, 16);
      }
      const resize = new ResizeObserver(schedule);
      document.addEventListener('scroll', schedule, true);
      window.addEventListener('resize', schedule);
      new MutationObserver(schedule).observe(document.documentElement,
        {subtree:true, childList:true, attributes:true});
      function focus() {
        const next = fields(document.activeElement);
        target = next ? {...next, token:String(++serial), url:location.href} : null;
        resize.disconnect();
        if (target) resize.observe(target.input);
        report();
      }
      document.addEventListener('focusin', focus, true);
      // Clicking elsewhere cancels a stale target; the native key button is outside DOM.
      document.addEventListener('pointerdown', e => { if (!fields(e.target)) {
        target = null;
        window.webkit.messageHandlers.origamiPasswordFocus.postMessage({url:location.href, token:''});
      } }, true);
      window.__origamiPasswordFill = {
        refresh: focus,
        fill(token, username, password) {
          const saved = target; target = null;
          if (!saved || saved.token !== token || saved.url !== location.href ||
              !saved.input.isConnected || document.activeElement !== saved.input) return false;
          const now = fields(saved.input);
          if (!now || now.form !== saved.form || now.username !== saved.username ||
              now.password !== saved.password || now.action !== saved.action) return false;
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          setter.call(now.username, username); setter.call(now.password, password);
          for (const input of [now.username, now.password]) {
            input.dispatchEvent(new Event('input', {bubbles:true, composed:true}));
            input.dispatchEvent(new Event('change', {bubbles:true, composed:true}));
          }
          return true;
        }
      };
      focus();
    })();
    """#
}
