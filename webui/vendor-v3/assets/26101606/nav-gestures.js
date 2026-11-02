"use strict";
// Pointer-only enhancement. Native button clicks and keyboard activation stay
// with HAUI; page selection is committed once, when a horizontal drag ends.
(() => {
  if(!window.PointerEvent||!window.HAUI)return;
  const nav=document.querySelector('.bottom-nav'),lens=nav.querySelector('.nav-indicator');
  const tabs=Array.from(nav.querySelectorAll('.nav-item'));
  let active=null,frame=0,blocked=null;
  const frames=window.HANavFrames;
  const put=(name,value)=>frames?frames.style(nav,name,value):nav.style.setProperty(name,value);
  function cancelFrame(){if(frames)frames.cancel('input','drag-position');else if(frame)cancelAnimationFrame(frame);frame=0;}
  const clamp=value=>Math.max(0,Math.min(tabs.length-1,value));
  const enabled=()=>tabs.every(tab=>!tab.disabled);
  function block(id){blocked={id,until:performance.now()+500};}
  function endCapture(id){try{if(nav.hasPointerCapture(id))nav.releasePointerCapture(id);}catch(_){}}
  function clean(){
    if(frame)cancelFrame();
    delete nav.dataset.navDragging;
    tabs.forEach(tab=>delete tab.dataset.navTarget);
    nav.style.removeProperty('--ha-nav-position');
    nav.dispatchEvent(new Event('ha:nav-end'));
  }
  function cancel(){
    if(!active)return;
    const old=active;active=null;block(old.id);
    clean();endCapture(old.id);
  }
  function paint(){
    frame=0;if(!active||active.phase!=='dragging')return;
    if(!enabled()){cancel();return;}
    const a=active;
    a.position=clamp((a.x-a.first-a.grab)/a.step);
    put('--ha-nav-position',a.position.toFixed(5));
    const preview=Math.round(a.position);
    if(preview!==a.preview){
      a.preview=preview;
      tabs.forEach((tab,i)=>{if(i===preview)tab.dataset.navTarget='true';else delete tab.dataset.navTarget;});
    }
    const growthX=parseFloat(nav.style.getPropertyValue('--glass-growth-x'))||1,growthY=parseFloat(nav.style.getPropertyValue('--glass-growth-y'))||1;
    const width=(parseFloat(nav.style.getPropertyValue('--glass-base-w'))||a.step)*growthX;
    const height=(parseFloat(nav.style.getPropertyValue('--glass-base-h'))||a.height)*growthY;
    const lift=parseFloat(nav.style.getPropertyValue('--glass-lift'))||0;
    const left=a.first+a.position*a.step-width/2,top=a.top+a.height/2-height/2-lift;
    const x=Math.max(0,Math.min(100,(a.x-left)/width*100));
    const y=Math.max(0,Math.min(100,(a.y-top)/height*100));
    nav.dispatchEvent(new CustomEvent('ha:nav-position',{detail:{position:a.position,hitX:x/100,hitY:y/100,time:performance.now()}}));
  }
  function queue(){if(!frame){if(frames){frame=1;frames.request('input','drag-position',paint);}else frame=requestAnimationFrame(paint);}}
  nav.addEventListener('pointerdown',event=>{
    if(document.documentElement.dataset.uiStyle==='md3'||document.documentElement.dataset.navFloating==='false'||event.isPrimary===false||event.button>0)return;
    blocked=null;
    if(active||!enabled())return;
    const button=event.target.closest('.nav-item');if(!button||button.disabled)return;
    const first=tabs[0].getBoundingClientRect(),next=tabs[1].getBoundingClientRect(),r=lens.getBoundingClientRect();
    const center=first.left+first.width/2,step=next.left+next.width/2-center;
    if(!Number.isFinite(step)||step<20||r.height<20)return;
    const visibleCenter=r.left+r.width/2;
    // Preserve the grab point when the finger is on the thumb. A drag started
    // on another tab instead brings the thumb under the finger.
    const visible=lens.querySelector('.nav-lens');
    const visibleWidth=visible&&document.documentElement.dataset.navMaterial==='liquid'?visible.getBoundingClientRect().width:r.width;
    const onLens=Math.abs(event.clientX-visibleCenter)<=visibleWidth/2+2;
    active={id:event.pointerId,phase:'pending',page:HAUI.current(),startX:event.clientX,startY:event.clientY,
      x:event.clientX,y:event.clientY,first:center,step,grab:onLens?event.clientX-visibleCenter:0,
      top:r.top,height:r.height,position:clamp((visibleCenter-center)/step),preview:-1};
  },{passive:true});
  window.addEventListener('pointermove',event=>{
    if(!active||active.id!==event.pointerId)return;
    if(!enabled()||(event.pointerType==='mouse'&&event.buttons===0)){cancel();return;}
    const a=active,dx=event.clientX-a.startX,dy=event.clientY-a.startY;
    if(a.phase==='pending'){
      if(Math.max(Math.abs(dx),Math.abs(dy))<6)return;
      if(Math.abs(dy)>Math.abs(dx)){cancel();return;}
      a.phase='dragging';nav.dataset.navDragging='true';
      nav.dispatchEvent(new Event('ha:nav-drag-start'));
      try{nav.setPointerCapture(a.id);}catch(_){}
    }
    a.x=event.clientX;a.y=event.clientY;
    if(event.cancelable)event.preventDefault();queue();
  },{passive:false});
  window.addEventListener('pointerup',event=>{
    if(!active||active.id!==event.pointerId)return;
    if(!enabled()){cancel();return;}
    const a=active;
    if(a.phase!=='dragging'){active=null;return;}
    a.x=event.clientX;a.y=event.clientY;
    if(frame)cancelFrame();paint();
    // Resolve the final finger position before re-enabling CSS snap animation.
    lens.getBoundingClientRect();
    const target=tabs[Math.round(a.position)];
    active=null;block(a.id);
    HAUI.show(target.dataset.page);
    clean();endCapture(a.id);
    if(event.cancelable)event.preventDefault();
  },{passive:false});
  nav.addEventListener('click',event=>{
    // A drag can still synthesize a click on its original/captured target.
    // Leave keyboard and accessibility clicks (detail=0) intact. A new genuine
    // pointerdown clears this guard, so the next quick tap is never swallowed.
    if(!blocked||event.detail===0||performance.now()>blocked.until)return;
    if(typeof event.pointerId==='number'&&event.pointerId>=0&&event.pointerId!==blocked.id)return;
    blocked=null;event.preventDefault();event.stopImmediatePropagation();
  },true);
  window.addEventListener('pointercancel',event=>{if(active&&event.pointerId===active.id)cancel();},{passive:true});
  nav.addEventListener('lostpointercapture',event=>{if(event.target===nav&&active&&event.pointerId===active.id)cancel();});
  nav.addEventListener('ha:nav-reset',cancel);
  window.addEventListener('blur',cancel);
  window.addEventListener('keydown',event=>{if(event.key==='Escape'&&active){event.preventDefault();cancel();}});
  window.addEventListener('pagehide',cancel);
  window.addEventListener('resize',cancel,{passive:true});
  if(window.visualViewport)window.visualViewport.addEventListener('resize',cancel,{passive:true});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)cancel();});
  new MutationObserver(()=>{if(active&&!enabled())cancel();}).observe(nav,{subtree:true,attributes:true,attributeFilter:['disabled']});
  new MutationObserver(()=>{if(active&&HAUI.current()!==active.page)cancel();}).observe(document.documentElement,{attributes:true,attributeFilter:['style']});
})();
