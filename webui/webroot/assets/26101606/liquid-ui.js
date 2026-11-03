"use strict";
// Entirely local visual preferences; no root or host layout commands.
(() => {
  const root=document.documentElement,nav=document.querySelector('.bottom-nav'),positionFrame=document.querySelector('.nav-indicator'),lens=positionFrame.querySelector('.nav-lens'),shell=nav.querySelector('.nav-glass-shell');
  // 导航项数量由 DOM 决定：指示器宽度、位置换算和拖拽上限都必须跟着它走，
  // 不能写死 3（原来 4 个 tab 时会错位、最后一个 tab 拖不过去）。
  const navCount=Math.max(1,nav.querySelectorAll('.nav-item').length);
  const material=document.getElementById('glass-material'),strength=document.getElementById('glass-strength');
  const key='hyperaudio.liquid-test1';
  const frames=window.HANavFrames;
  const put=(name,value)=>frames?frames.style(nav,name,value):nav.style.setProperty(name,value);
  function scheduleMotion(){if(frames){frames.request('paint','glass-motion',tick);return 1;}return requestAnimationFrame(tick);}
  function cancelMotion(){if(frames)frames.cancel('paint','glass-motion');else if(motion.frame)cancelAnimationFrame(motion.frame);}
  function read(){try{return JSON.parse(localStorage.getItem(key))||{};}catch(_){return {};}}
  const saved=read();
  material.value=['solid','blur','liquid'].includes(saved.material)?saved.material:'liquid';
  strength.value=['soft','normal','strong'].includes(saved.strength)?saved.strength:'normal';
  const supports=value=>{try{return !!window.CSS&&(CSS.supports('backdrop-filter',value)||CSS.supports('-webkit-backdrop-filter',value));}catch(_){return false;}};
  const hasBlur=supports('blur(8px)'),hasUrl=supports('url(#ha-liquid-probe)');
  const hasMask=!!window.CSS&&typeof CSS.supports==='function'&&(CSS.supports('mask-composite','exclude')||CSS.supports('-webkit-mask-composite','xor'));
  let instances=[],generation=0,frame=0,lastSize='';
  const reduced=window.matchMedia&&window.matchMedia('(prefers-reduced-motion: reduce)');
  let pointer=null;
  const motion={scale:1,scaleTarget:1,scaleVelocity:0,position:0,positionTarget:0,positionVelocity:0,frame:0,time:0,
    angle:-32,angleTarget:-32,angleVelocity:0,shineX:.45,shineXTarget:.45,shineXVelocity:0,
    shineY:.12,shineYTarget:.12,shineYVelocity:0,pace:0,paceTarget:0,paceVelocity:0,
    dragVelocity:0,lastSampleTime:0,lastSamplePosition:0,lastInput:0,hitX:.5,hitY:.35};
  function selected(){return Math.max(0,Math.min(navCount-1,parseFloat(root.style.getPropertyValue('--ha-nav-index'))||0));}
  const clamp=(a,b,v)=>Math.max(a,Math.min(b,v));
  function paintMotion(){
    put('--glass-activity',clamp(0,1,(motion.scale-1)/.30).toFixed(5));
    const x=1+(motion.scale-1)*.82,y=1+(motion.scale-1)*1.85;
    put('--glass-growth-x',x.toFixed(5));put('--glass-growth-y',y.toFixed(5));
    put('--glass-lift',((motion.scale-1)*18).toFixed(3)+'px');
    put('--glass-position',motion.position.toFixed(5));
    put('--glass-reflect-angle',motion.angle.toFixed(3)+'deg');
    put('--glass-reflect-x',(motion.shineX*100).toFixed(2)+'%');
    put('--glass-reflect-y',(motion.shineY*100).toFixed(2)+'%');
    put('--glass-speed',clamp(0,1,motion.pace).toFixed(5));
    if(instances[1])instances[1].update(x,y,motion.angle,1+.16*clamp(0,1,motion.pace));
  }
  function resetMotion(){
    if(motion.frame)cancelMotion();
    motion.frame=0;motion.time=0;motion.scale=motion.scaleTarget=1;
    motion.position=motion.positionTarget=selected();motion.scaleVelocity=motion.positionVelocity=0;
    motion.angle=motion.angleTarget=-32;motion.shineX=motion.shineXTarget=.45;motion.shineY=motion.shineYTarget=.12;motion.pace=motion.paceTarget=0;
    motion.angleVelocity=motion.shineXVelocity=motion.shineYVelocity=motion.paceVelocity=0;
    motion.dragVelocity=motion.lastSampleTime=motion.lastInput=0;motion.hitX=.5;motion.hitY=.35;paintMotion();
  }
  function lightTargets(now,dt){
    if(pointer!==null&&now-motion.lastInput>55){motion.dragVelocity*=Math.exp(-12*dt);if(Math.abs(motion.dragVelocity)<.004)motion.dragVelocity=0;}
    const v=pointer!==null?motion.dragVelocity:motion.positionVelocity;
    const drift=Math.tanh(v*.45),pressed=pointer!==null;
    motion.angleTarget=-32+drift*78+(pressed?(motion.hitX-.5)*28+(motion.hitY-.5)*8:0);
    motion.shineXTarget=clamp(.1,.9,.45+drift*.27+(pressed?(motion.hitX-.5)*.22:0));
    motion.shineYTarget=clamp(.05,.4,.12+(pressed?motion.hitY*.14:0)+Math.abs(drift)*.07);
    motion.paceTarget=clamp(0,1,Math.abs(v)/4);
  }
  function finishReduced(){
    if(motion.frame)cancelMotion();motion.frame=0;motion.time=0;
    motion.scale=motion.scaleTarget;motion.position=motion.positionTarget;motion.scaleVelocity=motion.positionVelocity=0;
    motion.angle=motion.angleTarget=-32;motion.shineX=motion.shineXTarget=.45;motion.shineY=motion.shineYTarget=.12;
    motion.pace=motion.paceTarget=0;motion.angleVelocity=motion.shineXVelocity=motion.shineYVelocity=motion.paceVelocity=0;paintMotion();
  }
  function tick(now){
    motion.frame=0;
    if(root.dataset.navMaterial!=='liquid'){resetMotion();return;}
    if(reduced&&reduced.matches){finishReduced();return;}
    const dt=motion.time?Math.min(.08,Math.max(.001,(now-motion.time)/1000)):1/60;motion.time=now;
    lightTargets(now,dt);let moving=false;
    for(const [value,target,velocity,stiffness,damping,tolerance] of [
      ['scale','scaleTarget','scaleVelocity',480,34,.0004],['position','positionTarget','positionVelocity',480,34,.0004],
      ['angle','angleTarget','angleVelocity',160,24,.01],['shineX','shineXTarget','shineXVelocity',160,24,.0004],
      ['shineY','shineYTarget','shineYVelocity',160,24,.0004],['pace','paceTarget','paceVelocity',180,25,.0004]]){
      // Preserve real-time settling at lower frame rates without unstable
      // large Euler steps. These scalar substeps do not repaint the filter.
      const steps=Math.ceil(dt*120),step=dt/steps;
      for(let i=0;i<steps;i++){
        motion[velocity]+=(stiffness*(motion[target]-motion[value])-damping*motion[velocity])*step;
        motion[value]+=motion[velocity]*step;
      }
      if(Math.abs(motion[target]-motion[value])<tolerance&&Math.abs(motion[velocity])<tolerance*10){motion[value]=motion[target];motion[velocity]=0;}
      if(motion[value]!==motion[target]||motion[velocity]!==0)moving=true;
    }
    motion.scale=clamp(.99,1.36,motion.scale);motion.position=clamp(0,navCount-1,motion.position);paintMotion();
    if(moving||Math.abs(motion.dragVelocity)>.004)motion.frame=scheduleMotion();else motion.time=0;
  }
  function animate(scale=motion.scaleTarget){
    motion.scaleTarget=scale;
    if(reduced&&reduced.matches){finishReduced();return;}
    if(!motion.frame)motion.frame=scheduleMotion();
  }
  function persist(){try{localStorage.setItem(key,JSON.stringify({material:material.value,strength:strength.value}));}catch(_){}}
  function plainFallback(){
    root.dataset.navMaterial=hasBlur?'blur':'solid';
  }
  function clear(){
    nav.dispatchEvent(new Event('ha:nav-reset'));release();
    resetMotion();
    instances.forEach(instance=>instance.destroy());instances=[];
    for(const element of [shell,lens]){element.style.backdropFilter='';element.style.removeProperty('-webkit-backdrop-filter');}
  }
  function apply(){
    const token=++generation;clear();
    root.dataset.navMaterial='solid';
    root.dataset.glassStrength=strength.value;
    document.getElementById('glass-strength-row').hidden=material.value!=='liquid';
    if(root.dataset.navFloating==='false'||root.dataset.uiStyle==='md3'||material.value==='solid')return;
    if(material.value==='blur'){
      if(hasBlur)root.dataset.navMaterial='blur';
      return;
    }
    if(!hasUrl||!hasMask){plainFallback();return;}
    const rect=positionFrame.getBoundingClientRect();
    if(rect.width<32||rect.height<24)return;
    const w=Math.round(rect.width),h=Math.round(rect.height);
    put('--glass-base-w',w+'px');put('--glass-base-h',h+'px');
    put('--glass-step',rect.width+'px');
    const svg='<svg xmlns="http://www.w3.org/2000/svg" width="'+w+'" height="'+h+'"><rect width="100%" height="100%" rx="'+h/2+'" fill="white"/></svg>';
    put('--glass-cutout','url("data:image/svg+xml,'+encodeURIComponent(svg)+'")');
    try{
      instances.push(window.HALiquidGlass.create(shell,{strength:strength.value,profile:'bar'}));
      instances[0].ready.catch(()=>{});
      instances.push(window.HALiquidGlass.create(lens,{strength:strength.value,profile:'control',width:w,height:h}));
      instances[1].ready.catch(()=>{});
      Promise.all(instances.map(instance=>instance.ready)).then(()=>{
        if(token!==generation)return;
        root.dataset.navMaterial='liquid';resetMotion();
      }).catch(()=>{if(token===generation){clear();plainFallback();}});
    }catch(_){clear();plainFallback();}
  }
  function refreshMenus(){if(window.HASelectMenus)window.HASelectMenus.refresh();}
  material.addEventListener('change',()=>{persist();apply();});
  strength.addEventListener('change',()=>{persist();if(material.value==='liquid')apply();});
  function light(event){
    const button=event.target.closest('.nav-item'),r=(button||lens).getBoundingClientRect();
    if(r.width<=0||r.height<=0)return;
    const x=Math.max(0,Math.min(100,(event.clientX-r.left)/r.width*100));
    const y=Math.max(0,Math.min(100,(event.clientY-r.top)/r.height*100));
    motion.hitX=x/100;motion.hitY=y/100;motion.lastInput=performance.now();
  }
  function release(event){
    if(event&&event.type.startsWith('pointer')&&(pointer===null||event.pointerId!==pointer))return;
    pointer=null;motion.positionTarget=selected();motion.dragVelocity=0;motion.lastSampleTime=0;
    if(root.dataset.navMaterial==='liquid')animate(1);else resetMotion();
  }
  nav.addEventListener('pointerdown',event=>{
    if(root.dataset.navMaterial!=='liquid'||event.isPrimary===false||event.button>0)return;
    if(!event.target.closest('.nav-item')||event.target.closest('.nav-item').disabled)return;
    pointer=event.pointerId;motion.dragVelocity=0;motion.lastSampleTime=0;light(event);animate(1.10);
  },{passive:true});
  nav.addEventListener('pointermove',event=>{if(pointer===event.pointerId&&nav.dataset.navDragging!=='true')light(event);},{passive:true});
  nav.addEventListener('ha:nav-end',()=>release());
  nav.addEventListener('ha:nav-drag-start',()=>{if(root.dataset.navMaterial==='liquid')animate(1.30);});
  nav.addEventListener('ha:nav-position',event=>{
    if(root.dataset.navMaterial!=='liquid')return;
    const {position,hitX=.5,hitY=.35,time=performance.now()}=event.detail;
    if(motion.lastSampleTime){const dt=clamp(1/240,.08,(time-motion.lastSampleTime)/1000),velocity=clamp(-9,9,(position-motion.lastSamplePosition)/dt);motion.dragVelocity=.5*motion.dragVelocity+.5*velocity;}
    motion.lastSampleTime=motion.lastInput=time;motion.lastSamplePosition=position;motion.hitX=hitX;motion.hitY=hitY;
    motion.position=motion.positionTarget=position;motion.positionVelocity=0;animate();
  });
  new MutationObserver(()=>{
    if(root.dataset.navMaterial!=='liquid'||nav.dataset.navDragging==='true')return;
    const target=selected();if(target===motion.positionTarget)return;motion.positionTarget=target;animate();
  }).observe(root,{attributes:true,attributeFilter:['style']});
  window.addEventListener('pointerup',release,{passive:true});
  window.addEventListener('pointercancel',release,{passive:true});
  window.addEventListener('blur',release);
  document.addEventListener('visibilitychange',()=>{if(document.hidden){release();resetMotion();}});
  function geometry(){
    frame=0;const rect=nav.getBoundingClientRect(),size=Math.round(rect.width)+':'+Math.round(rect.height);
    if(size!==lastSize){lastSize=size;if(material.value==='liquid')apply();}
  }
  function queueGeometry(){if(!frame)frame=requestAnimationFrame(geometry);}
  if(window.ResizeObserver)new ResizeObserver(queueGeometry).observe(nav);
  window.addEventListener('resize',queueGeometry,{passive:true});
  window.addEventListener('pagehide',()=>{++generation;release();clear();});
  window.addEventListener('pageshow',e=>{if(e.persisted)apply();});
  window.addEventListener('ha:appearance',()=>{apply();refreshMenus();});
  refreshMenus();geometry();
  if(material.value!=='liquid')apply();
})();
