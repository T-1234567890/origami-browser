import WebKit

enum ActivityScript {
    static let source = """
    (()=>{
      let connections=new Set(), dirty=false, muted=false, blockAutoplay=false, interacted=false;
      const Native=window.RTCPeerConnection;
      if(Native) window.RTCPeerConnection=new Proxy(Native,{construct(target,args,newTarget){const pc=Reflect.construct(target,args,newTarget);connections.add(pc);pc.addEventListener('connectionstatechange',()=>{if(['closed','failed'].includes(pc.connectionState))connections.delete(pc)});return pc}});
      const sockets=new Set();
      for(const name of ['WebSocket','EventSource']){
        const Constructor=window[name];
        if(Constructor)window[name]=new Proxy(Constructor,{construct(target,args,newTarget){const connection=Reflect.construct(target,args,newTarget);sockets.add(connection);return connection}});
      }
      for(const event of ['pointerdown','keydown'])addEventListener(event,e=>{if(e.isTrusted)interacted=true},true);
      addEventListener('play',e=>{if(blockAutoplay&&!interacted&&e.target instanceof HTMLMediaElement)e.target.pause()},true);
      addEventListener('input',e=>{if(e.target.isContentEditable)dirty=true},true);
      addEventListener('submit',()=>{dirty=false},true);
      function elements(){return [...document.querySelectorAll('audio,video')]}
      Object.defineProperty(window,'__origamiActivity',{value:Object.freeze({
        get canManuallySleep(){return !dirty && !connections.size && !elements().some(e=>!e.paused&&!e.ended) && ![...document.querySelectorAll('input,textarea,select')].some(e=>{
          if(e.type==='file')return e.files.length>0;
          if(e.type==='checkbox'||e.type==='radio')return e.checked!==e.defaultChecked;
          if(e.tagName==='SELECT'){const options=[...e.options], explicit=options.some(o=>o.defaultSelected);return options.some((o,i)=>o.selected!==(explicit?o.defaultSelected:(!e.multiple&&i===0)))}
          return e.value && e.value!==e.defaultValue;
        })},
        get safeToSleep(){return this.canManuallySleep && ![...sockets].some(s=>s.readyState!==s.CLOSED) && !document.querySelector('iframe')},
        setAutoplayPolicy(block){blockAutoplay=!!block;if(blockAutoplay&&!interacted)elements().forEach(e=>{e.autoplay=false;if(!e.paused)e.pause()})},
        setMuted(value){muted=!!value;elements().forEach(e=>e.muted=muted)},
        get muted(){let e=elements();return e.length?e.every(x=>x.muted):null}
      }),writable:false,configurable:false});
      new MutationObserver(()=>{if(muted)elements().forEach(e=>e.muted=true)}).observe(document,{childList:true,subtree:true});
    })();
    """
}
