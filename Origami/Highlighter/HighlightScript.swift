import WebKit

enum HighlightScript {
    static let world = WKContentWorld.world(name: "Origami.WebHighlighter")
    static let source = #"""
    (() => {
      if (window.__origamiHighlighter || !/^https?:$/.test(location.protocol)) return;
      const documentID = crypto.randomUUID(), styles = ['yellow','mint','lavender'];
      const names = styles.map(s => 'origami-' + s + '-' + documentID.replaceAll('-',''));
      const blocked = 'script,style,noscript,form,input,textarea,select,option,button,a,summary,[role=combobox],[role=searchbox],[contenteditable], [role=textbox],[role=button],[hidden],[aria-hidden=true]';
      let enabled=false, erasing=false, records=[], rendered=[], pending=null, serial=0, route=location.href, timer, attempts=0, lastRestore=0;
      const supported = !!(window.Highlight && CSS.highlights && window.CSSStyleSheet);
      const send = value => window.webkit.messageHandlers.origamiHighlight.postMessage({documentID,url:location.href,...value});
      const normalize = s => s.replace(/\s+/g,' ').trim();
      const safe = node => node && node.nodeType===Node.TEXT_NODE && !node.parentElement?.closest(blocked) &&
          node.parentElement?.getClientRects().length && getComputedStyle(node.parentElement).visibility==='visible';
      function index() {
        const entries=[]; let raw='';
        const walk=document.createTreeWalker(document.body || document.documentElement,NodeFilter.SHOW_TEXT);
        let node, visited=0;
        while ((node=walk.nextNode()) && ++visited<=10000 && raw.length<200000) {
          if (!safe(node)) continue;
          const part=node.data.slice(0,200000-raw.length);
          entries.push({node,start:raw.length,end:raw.length+part.length}); raw+=part;
        }
        let text='', map=[];
        for(let i=0;i<raw.length;i++) {
          if (/\s/.test(raw[i])) { if (text.endsWith(' ')) continue; text+=' '; }
          else text+=raw[i];
          map.push(i);
        }
        return {entries,raw,text,map};
      }
      function offsets(range, ix) {
        const start=ix.entries.find(e=>e.node===range.startContainer), end=ix.entries.find(e=>e.node===range.endContainer);
        if (!start || !end) return null;
        let a=ix.map.findIndex(i=>i>=start.start+range.startOffset), b=ix.map.findIndex(i=>i>=end.start+range.endOffset);
        if (b<0) b=ix.text.length;
        if (a<0 || b<=a) return null;
        while(ix.text[a]===' ') a++; while(ix.text[b-1]===' ') b--;
        return b>a ? [a,b] : null;
      }
      function safeRange(range) {
        if (!safe(range.startContainer) || !safe(range.endContainer)) return false;
        const root=range.commonAncestorContainer.nodeType===1 ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement;
        const forbidden=root.querySelectorAll(blocked);
        if(forbidden.length>1000) return false;
        return ![...forbidden].some(node=>range.intersectsNode(node));
      }
      function rangeAt(ix,start,end) {
        const a=ix.map[start], b=end<ix.map.length ? ix.map[end] : ix.raw.length;
        const first=ix.entries.find(e=>e.start<=a && e.end>a), last=ix.entries.find(e=>e.start<b && e.end>=b);
        if(!first || !last) return null;
        const range=document.createRange(); range.setStart(first.node,a-first.start); range.setEnd(last.node,b-last.start);
        return safeRange(range) ? range : null;
      }
      function path(node) {
        const result=[];
        while(node && node!==document.body && result.length<64) {
          if(!node.parentNode) return [];
          result.unshift([...node.parentNode.childNodes].indexOf(node)); node=node.parentNode;
        }
        return node===document.body ? result : [];
      }
      function nodeAt(path) { let node=document.body; for(const i of path) node=node?.childNodes[i]; return node; }
      function contextScore(ix,a,b,anchor) {
        let matched=0,total=0;
        const before=ix.text.slice(Math.max(0,a-anchor.prefix.length),a), after=ix.text.slice(b,b+anchor.suffix.length);
        for(let i=1;i<=anchor.prefix.length;i++) { total++; if(before.at(-i)===anchor.prefix.at(-i)) matched++; }
        for(let i=0;i<anchor.suffix.length;i++) { total++; if(after[i]===anchor.suffix[i]) matched++; }
        return total ? matched/total : 0;
      }
      function resolve(anchor,ix) {
        const quote=anchor.text;
        if(!quote || quote.length>8000) return null;
        const candidates=[];
        let pos=ix.text.indexOf(quote);
        while(pos>=0 && candidates.length<100) {
          candidates.push({a:pos,b:pos+quote.length,score:contextScore(ix,pos,pos+quote.length,anchor)});
          pos=ix.text.indexOf(quote,pos+1);
        }
        if(pos>=0) return null; // Too common to anchor safely.
        candidates.sort((a,b)=>b.score-a.score);
        let match=candidates[0];
        if(match && ((candidates.length>1 && (match.score<0.75 || match.score-(candidates[1]?.score||0)<0.2)) ||
            (quote.length<24 && match.score<0.75))) match=null;
        if(match) {
          // Verify the stored DOM hint before using it. The quote/context still decides identity.
          try {
            const range=document.createRange(); range.setStart(nodeAt(anchor.startPath),anchor.startOffset); range.setEnd(nodeAt(anchor.endPath),anchor.endOffset);
            const p=offsets(range,ix);
            if(p && p[0]===match.a && p[1]===match.b && safeRange(range) && normalize(range.toString())===quote) return range;
          } catch(_) {}
          return rangeAt(ix,match.a,match.b);
        }
        if(candidates.length || quote.length<32 || quote.length>2000 || anchor.prefix.length<16 || anchor.suffix.length<16) return null;
        // Conservative fuzzy fallback: unique, unchanged context on BOTH sides and one small text edit.
        const pre=anchor.prefix.slice(-24), post=anchor.suffix.slice(0,24);
        const before=ix.text.indexOf(pre);
        if(before<0 || ix.text.indexOf(pre,before+1)>=0) return null;
        const a=before+pre.length, b=ix.text.indexOf(post,a);
        if(b<a || ix.text.indexOf(post,b+1)>=0) return null;
        const candidate=ix.text.slice(a,b);
        let left=0,right=0;
        while(left<Math.min(quote.length,candidate.length) && quote[left]===candidate[left]) left++;
        while(right<Math.min(quote.length,candidate.length)-left && quote.at(-1-right)===candidate.at(-1-right)) right++;
        const difference=Math.max(quote.length,candidate.length)-left-right;
        if(difference>Math.min(12,Math.floor(quote.length*0.08))) return null;
        return rangeAt(ix,a,b);
      }
      function clear() { if(supported) names.forEach(n=>CSS.highlights.delete(n)); rendered=[]; pending=null; }
      function restore() {
        if(!supported || location.href!==route) return;
        lastRestore=performance.now(); attempts++;
        if(!records.length) { names.forEach(n=>CSS.highlights.delete(n)); rendered=[]; return; }
        const ix=index(), groups=styles.map(()=>new Highlight()); rendered=[];
        for(const record of records.slice(0,200)) {
          const range=resolve(record.anchor,ix), i=styles.indexOf(record.style);
          if(range && i>=0) { groups[i].add(range); rendered.push({id:record.id,range}); }
        }
        groups.forEach((group,i)=>CSS.highlights.set(names[i],group));
      }
      function schedule() {
        clearTimeout(timer);
        if(attempts>=20) return;
        timer=setTimeout(()=>{
          restore();
          // Unrelated page updates must not invalidate an unchanged selection.
          if(pending) {
            if(!safeRange(pending.range) || normalize(pending.range.toString())!==pending.value.anchor.text) {
              pending=null; send({kind:'hide'});
            } else {
              const rect=pending.range.getBoundingClientRect();
              if(!rect.width || !rect.height || rect.bottom<0 || rect.top>innerHeight) {
                pending=null; send({kind:'hide'});
              } else {
                pending.value.x=Math.max(0,Math.min(1,rect.left/innerWidth));
                pending.value.y=Math.max(0,Math.min(1,rect.bottom/innerHeight));
                send({kind:'selection',...pending.value});
              }
            }
          }
        },Math.max(250,1000-(performance.now()-lastRestore)));
      }
      function checkRoute() {
        if(location.href===route) return;
        clear(); records=[]; attempts=0; route=location.href; clearTimeout(timer);
        send({kind:'ready',supported});
      }
      function selection() {
        pending=null;
        if(!enabled || !supported || location.href!==route) return null;
        const selected=getSelection();
        if(!selected || selected.rangeCount!==1 || selected.isCollapsed) return null;
        const range=selected.getRangeAt(0).cloneRange();
        if(!safeRange(range) || range.toString().length>8000) return null;
        const ix=index(), p=offsets(range,ix); if(!p) return null;
        const [a,b]=p, rect=range.getBoundingClientRect();
        if(!rect.width || !rect.height || rect.bottom<0 || rect.top>innerHeight) return null;
        const existing=rendered.filter(item=>{const p=offsets(item.range,ix);return p && p[0]<b && p[1]>a;});
        if(existing.length>1) return null;
        const anchor={text:ix.text.slice(a,b),prefix:ix.text.slice(Math.max(0,a-64),a),suffix:ix.text.slice(b,b+64),
          startPath:path(range.startContainer),endPath:path(range.endContainer),startOffset:range.startOffset,endOffset:range.endOffset,position:a};
        const value={anchor,token:++serial,existingID:existing.length===1 ? existing[0].id : null,
          x:Math.max(0,Math.min(1,rect.left/innerWidth)), y:Math.max(0,Math.min(1,rect.bottom/innerHeight))};
        pending={value,range}; return value;
      }
      if(supported) {
        const sheet=new CSSStyleSheet();
        sheet.replaceSync(names.map((name,i)=>`::highlight(${name}) { background-color: ${['rgba(230,191,73,.38)','rgba(77,176,146,.34)','rgba(157,129,206,.34)'][i]}; }`).join('\n'));
        document.adoptedStyleSheets=[...document.adoptedStyleSheets,sheet];
      }
      window.__origamiHighlighter=Object.freeze({
        resume() { checkRoute(); send({kind:'ready',supported}); },
        configure(value) {
          if(value.documentID!==documentID || value.url!==location.href) return;
          enabled=value.enabled; erasing=value.erasing===true; records=value.records; pending=null; attempts=0; restore();
        },
        selection,
        snapshot(token) {
          if(!enabled || location.href!==route || pending?.value.token!==token || !safeRange(pending.range) || normalize(pending.range.toString())!==pending.value.anchor.text) return null;
          return pending.value;
        },
        resolveAnchor: anchor => { const range=resolve(anchor,index()); return range?.toString() || null; },
        dispose() { clear(); clearTimeout(timer); clearInterval(poll); observer.disconnect(); }
      });
      const update=e=>{
        if(!e.isTrusted || e.target?.closest?.(blocked)) return;
        checkRoute();
        if(enabled && erasing && e.type==='pointerup' && getSelection()?.isCollapsed) {
          const hit=rendered.find(item=>safeRange(item.range) && [...item.range.getClientRects()].some(r=>e.clientX>=r.left && e.clientX<=r.right && e.clientY>=r.top && e.clientY<=r.bottom));
          if(hit) { const selected=getSelection(); selected.removeAllRanges(); selected.addRange(hit.range.cloneRange()); }
        }
        const value=selection();
        send(value ? {kind:'selection',commit:true,...value} : {kind:'hide'});
      };
      document.addEventListener('pointerup',update,true); document.addEventListener('keyup',update,true);
      document.addEventListener('scroll',()=>{pending=null;send({kind:'hide'});},true);
      addEventListener('resize',()=>{pending=null;send({kind:'hide'});});
      addEventListener('pageshow',()=>{pending=null;route=location.href;send({kind:'ready',supported});});
      addEventListener('pagehide',()=>{pending=null;clearTimeout(timer);});
      addEventListener('popstate',checkRoute); addEventListener('hashchange',checkRoute);
      const observer=new MutationObserver(()=>{checkRoute(); if(records.length) schedule();});
      observer.observe(document.body || document.documentElement,{childList:true,subtree:true,characterData:true});
      const poll=setInterval(checkRoute,500);
      send({kind:'ready',supported});
    })();
    """#
}
