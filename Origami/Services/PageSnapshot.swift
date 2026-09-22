import Foundation

enum PageSnapshot {
    // Preserve rendered style and CSSOM changes instead of relying on removed scripts to recreate them.
    static let script = #"""
    await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 1500))]);
    let count = 0;
    const properties = ('display position top right bottom left width height min-width min-height max-width max-height box-sizing ' +
      'margin padding border border-radius background color font-family font-size font-weight font-style line-height letter-spacing text-align text-transform white-space ' +
      'opacity visibility transform transform-origin overflow overflow-x overflow-y z-index clip-path filter object-fit object-position ' +
      'flex flex-direction flex-wrap align-items align-self justify-content gap order grid-template-columns grid-template-rows grid-column grid-row ' +
      'content box-shadow text-shadow vertical-align list-style').split(' ');
    function snapshot(doc, depth = 0) {
      const root = doc.documentElement.cloneNode(true), originals = [...doc.querySelectorAll('*')];
      const copies = [root, ...root.querySelectorAll('*')];
      const pseudoRules = [];
      for (let i = 0; i < originals.length; i++) {
        if (++count > 40000) throw new Error('Page is too large to save');
        const original = originals[i], copy = copies[i];
        if (!copy || ['SCRIPT', 'STYLE', 'LINK', 'META', 'HEAD'].includes(original.tagName)) continue;
        const style = doc.defaultView.getComputedStyle(original);
        for (const property of properties) { const value = style.getPropertyValue(property); if (value) copy.style.setProperty(property, value); }
        copy.style.setProperty('animation', 'none', 'important');
        copy.style.setProperty('transition', 'none', 'important');
        for (const pseudo of ['::before', '::after']) {
          const computed = doc.defaultView.getComputedStyle(original, pseudo);
          if (!computed.content || ['none', 'normal'].includes(computed.content)) continue;
          const marker = 'origami-saved-' + count;
          copy.classList.add(marker);
          const declarations = properties.map(key => key + ':' + computed.getPropertyValue(key) + ';').join('');
          pseudoRules.push('.' + marker + pseudo + '{' + declarations + '}');
        }
        if (original.tagName === 'IMG') {
          const src = original.currentSrc || original.src || original.getAttribute('data-src');
          if (src) copy.setAttribute('src', src);
          copy.removeAttribute('loading');
        }
        if (original.tagName === 'CANVAS') {
          try { const img = doc.createElement('img'); img.src = original.toDataURL(); img.style.cssText = copy.style.cssText; copy.replaceWith(img); }
          catch (_) { copy.setAttribute('data-origami-unavailable', 'canvas'); }
        }
        if (original.tagName === 'IFRAME' && depth < 8) {
          try { if (original.contentDocument?.documentElement) { copy.setAttribute('srcdoc', snapshot(original.contentDocument, depth + 1)); copy.removeAttribute('src'); } } catch (_) {}
        }
        if (original.shadowRoot) {
          // Preserve declarative open shadow DOM; scoped styling is retained in the template.
          const template = doc.createElement('template'); template.setAttribute('shadowrootmode', 'open');
          template.innerHTML = original.shadowRoot.innerHTML;
          for (const sheet of original.shadowRoot.adoptedStyleSheets || []) {
            const styleNode = doc.createElement('style'); styleNode.textContent = [...sheet.cssRules].map(r => r.cssText).join('\n'); template.content.prepend(styleNode);
          }
          copy.prepend(template);
        }
      }
      let head = root.querySelector('head');
      if (!head) { head = doc.createElement('head'); root.prepend(head); }
      // CSSOM includes rules inserted at runtime that are absent from <style>.textContent.
      for (const sheet of doc.styleSheets) {
        try {
          if (sheet.href) continue;
          const style = doc.createElement('style'); style.textContent = [...sheet.cssRules].map(r => r.cssText).join('\n'); head.append(style);
        } catch (_) {}
      }
      for (const sheet of doc.adoptedStyleSheets || []) {
        const style = doc.createElement('style'); style.textContent = [...sheet.cssRules].map(r => r.cssText).join('\n'); head.append(style);
      }
      const pseudo = doc.createElement('style'); pseudo.textContent = pseudoRules.join('\n'); head.append(pseudo);
      root.querySelectorAll('base, meta[charset], meta[http-equiv="content-type" i]').forEach(node => node.remove());
      const base = doc.createElement('base'); base.href = doc.baseURI; head.prepend(base);
      const charset = doc.createElement('meta'); charset.setAttribute('charset', 'utf-8'); head.prepend(charset);
      root.querySelectorAll('input').forEach(node => { if (!['button', 'submit', 'reset'].includes(node.type)) { node.removeAttribute('value'); node.removeAttribute('checked'); } });
      root.querySelectorAll('textarea').forEach(node => { node.textContent = ''; });
      const html = '<!DOCTYPE html>\n' + root.outerHTML;
      if (html.length > 20000000) throw new Error('Page is too large to save');
      return html;
    }
    return snapshot(document);
    """#
}
