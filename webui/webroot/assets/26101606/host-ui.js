"use strict";
// Layout only: documented bridges, no root commands or fullscreen/icon APIs.
// Bridge acceptance does not acknowledge an Android frame or cancel a call.
(() => {
  const root=document.documentElement, media=window.matchMedia?window.matchMedia('(prefers-color-scheme: dark)'):null;
  let api='',control=null;
  try {
    if(window.ksu&&typeof window.ksu.enableEdgeToEdge==='function') {api='enableEdgeToEdge';control=v=>window.ksu.enableEdgeToEdge(v);}
    else if(window.ksu&&typeof window.ksu.enableInsets==='function') {api='enableInsets';control=v=>window.ksu.enableInsets(v);}
  }catch (_) {}
  let desired=false,applied=null,targetLayout='waiting',activeCall=null,forceNext=false,correctionNext=false;
  let probeTimer=null,loadTimer=null,resizeTimer=null,probeCycle=0,probing=false,attempt=0;
  let css='not_requested',layout='starting',reason='',insetPaused=false,bridgePaused=false,loadedOnce=false;
  let contextKey='',wasHidden=document.hidden;
  const safe={top:38,bottom:0,left:0,right:0};
  const probe=document.createElement('div');
  probe.setAttribute('aria-hidden','true');
  probe.style.cssText='position:fixed;visibility:hidden;pointer-events:none;width:0;height:0;'+
    ['top','bottom','left','right'].map(side=>'padding-'+side+':max(var(--window-inset-'+side+',0px),var(--safe-area-inset-'+side+',0px),var(--inset-'+side+',0px),env(safe-area-inset-'+side+',0px));').join('');
  document.body.appendChild(probe);
  function hostTheme(){
    try {if(window.webui&&typeof window.webui.isDarkMode==='boolean')return window.webui.isDarkMode?'dark':'light';}catch (_) {}
    return media?(media.matches?'dark':'light'):'unknown';
  }
  function themeKey(){return root.dataset.theme+'|'+hostTheme();}
  function setSafe(values){
    for(const side of Object.keys(safe))if(safe[side]!==values[side]){
      safe[side]=values[side];root.style.setProperty('--ha-safe-'+side,values[side]+'px');
    }
  }
  function measure(){
    const result={};
    try {
      const style=window.getComputedStyle(probe);
      for(const side of Object.keys(safe)){
        const value=parseFloat(style.getPropertyValue('padding-'+side));
        // An invalid side makes the whole sample unreliable. A real zero top
        // remains valid when landscape side/bottom avoidance is available.
        if(!Number.isFinite(value)||value<0||value>200)return null;
        result[side]=value;
      }
    }catch (_) {return null;}
    return result;
  }
  function render(){
    root.dataset.hostLayout=layout;
  }
  function cancelProbe(){
    clearTimeout(probeTimer);probeTimer=null;probing=false;probeCycle++;
  }
  function conservativeSafe(){
    // A failed native call might leave edge mode active. Preserve the last
    // bottom/side avoidance and a conservative top until state is accepted.
    setSafe({...safe,top:Math.max(38,safe.top)});
  }
  function nativeLayout(state){
    layout=state;
    if(applied===false)setSafe({top:0,bottom:0,left:0,right:0});
    else conservativeSafe();
    render();
  }
  function measureEdge(cycle){
    if(!probing||cycle!==probeCycle||!desired||applied!==true||document.hidden)return;
    const values=measure();
    if(values&&Object.values(values).some(value=>value>0)){
      cancelProbe();setSafe(values);layout='edge';reason='';render();return;
    }
    if(++attempt<20){
      // Keep a working sample during transient zeros. Resize/refresh events
      // share this probe's budget rather than restarting its retry timer.
      if(Object.values(safe).every(value=>value===0))conservativeSafe();
      probeTimer=setTimeout(()=>measureEdge(cycle),100);return;
    }
    cancelProbe();insetPaused=true;reason='insets_unavailable';
    desired=false;targetLayout='missing';reconcile();
  }
  function onApplied(){
    if(!desired){cancelProbe();reason=targetLayout==='missing'?'insets_unavailable':'';nativeLayout(targetLayout);return;}
    if(document.hidden){render();return;}
    if(!probing){probing=true;attempt=0;const cycle=++probeCycle;measureEdge(cycle);}
  }
  function deny(message){
    cancelProbe();applied=null;bridgePaused=true;reason=message;layout='denied';conservativeSafe();render();
  }
  function lateSettled(call){
    if(activeCall!==call)return;
    activeCall=null;applied=null;
    if(call.correction){
      // The correction itself timed out. Its late result must not launch a
      // second correction or claim that the native frame has been confirmed.
      render();return;
    }
    bridgePaused=false;reason='';forceNext=true;correctionNext=true;
    reconcile();
  }
  function reconcile(){
    // Keep timed-out promises active until they settle: JS cannot cancel the
    // native operation, so starting another one could reorder the layouts.
    if(activeCall||bridgePaused){render();return;}
    if(applied===desired&&!forceNext){onApplied();return;}
    cancelProbe();
    if(layout!=='edge'||applied!==desired)layout='waiting';
    const call={value:desired,correction:correctionNext,timedOut:false,timer:null};
    activeCall=call;forceNext=false;correctionNext=false;
    call.timer=setTimeout(()=>{
      if(activeCall!==call)return;
      call.timedOut=true;deny('bridge_timeout');
    },3000);
    // One promise handles both sync exceptions and async rejections. After a
    // timeout its settlement performs at most one forced correction.
    Promise.resolve().then(()=>{
      // Media listeners may update the page theme in the same event. Merge
      // those changes before entering the native bridge to avoid a brief
      // false/true pair for a theme that already agrees with the host.
      call.value=desired;forceNext=false;
      return control(call.value);
    }).then(result=>{
      if(activeCall!==call)return;
      clearTimeout(call.timer);
      if(call.timedOut){lateSettled(call);return;}
      activeCall=null;
      if(result===false){deny('bridge_rejected');return;}
      applied=call.value;
      if(call.correction&&(desired!==call.value||forceNext)){
        deny('bridge_target_changed');return;
      }
      reconcile();
    },error=>{
      if(activeCall!==call)return;
      clearTimeout(call.timer);
      if(call.timedOut){lateSettled(call);return;}
      activeCall=null;deny(String(error&&error.message||error));
    });
    render();
  }
  function refresh(force=false){
    const page=root.dataset.theme,host=hostTheme(),nextKey=themeKey();
    if(contextKey&&contextKey!==nextKey){insetPaused=false;cancelProbe();}
    contextKey=nextKey;
    if(!control){layout='unsupported';setSafe({top:Math.max(38,measure()?.top||0),bottom:0,left:0,right:0});render();return;}
    if(host==='unknown')targetLayout='unknown';
    else if(page!==host)targetLayout='contrast';
    else if(css==='loading')targetLayout='waiting';
    else if(insetPaused)targetLayout='missing';
    else targetLayout='edge';
    desired=targetLayout==='edge';
    if(!desired)cancelProbe();
    if(!bridgePaused)reason=targetLayout==='missing'?'insets_unavailable':'';
    if(force)forceNext=true;
    if(!bridgePaused&&(applied!==desired||forceNext))layout='waiting';
    reconcile();
  }
  function retry(){
    // An unresolved bridge cannot be safely restarted, even by a manual tap.
    if(activeCall){render();return;}
    insetPaused=false;bridgePaused=false;reason='';cancelProbe();refresh();
  }
  function checkTheme(){if(contextKey!==themeKey())refresh();}
  window.HAHostUI={refresh,retry,checkTheme};
  if(control){
    css='loading';refresh();
    const link=document.createElement('link');link.rel='stylesheet';link.href='/internal/insets.css';
    function settled(state){
      clearTimeout(loadTimer);css=state;
      if(state==='loaded'&&!loadedOnce){loadedOnce=true;insetPaused=false;cancelProbe();}
      // The stylesheet can enable native edge mode itself, including on a
      // late load. Reapply the target without clearing a failed bridge latch.
      refresh(true);
    }
    link.onload=()=>settled('loaded');link.onerror=()=>settled('unavailable');
    loadTimer=setTimeout(()=>settled('timeout'),3000);
    document.head.appendChild(link);
  }else refresh();
  if(media){const changed=()=>refresh();if(media.addEventListener)media.addEventListener('change',changed);else if(media.addListener)media.addListener(changed);}
  window.addEventListener('resize',()=>{
    clearTimeout(resizeTimer);
    resizeTimer=setTimeout(()=>{resizeTimer=null;if(!document.hidden)refresh();},120);
  });
  document.addEventListener('visibilitychange',()=>{
    clearTimeout(resizeTimer);resizeTimer=null;
    const returned=wasHidden&&!document.hidden;wasHidden=document.hidden;
    if(document.hidden)cancelProbe();else if(returned)retry();else checkTheme();
  });
})();
