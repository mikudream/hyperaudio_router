/*
 * HyperAudio's bounded WebUI adaptation of rizzytoday/liquid-glass.
 * Copyright (c) 2026 Riz Roze. MIT; see vendor/liquid-glass-LICENSE.txt.
 * SVG RGB displacement pipeline adapted from the upstream project.
 * Capsule-normal lens map, exact pixel filter bounds and lifecycle are new.
 * Modified by HyperAudio Switch: shared frame updates, unchanged-attribute
 * elision and proportional filter bounds. Optical presets are unchanged.
 * Full lower-edge refraction is restored. Original navigation labels occupy
 * the foreground plane above this surface; page content remains behind it.
 * Surface/refraction background: https://kube.io/blog/liquid-glass-css-svg/
 * This requests an SVG backdrop filter; it cannot verify Android GPU output.
 */
"use strict";
window.HALiquidGlass = (() => {
  const ns='http://www.w3.org/2000/svg';
  let serial=0;
  function attr(element,name,value){value=String(value);if(element.getAttribute(name)!==value)element.setAttribute(name,value);}
  // At most the two current optical surfaces. No page capture or render loop.
  const cache=new Map();
  const presets={
    // Every thumb stays clear. Presets mainly vary the edge and its response
    // while lifted; the surrounding bar keeps the same quieter material.
    soft:{control:.9,bar:1,controlBlur:.18,barBlur:1.6,saturate:1.03,brightness:1.008,rim:1.1,rimBoost:.5,dispersion:.012},
    normal:{control:1.1,bar:1,controlBlur:.06,barBlur:1.6,saturate:1.06,brightness:1.018,rim:1.55,rimBoost:1.05,dispersion:.018},
    strong:{control:1.5,bar:1,controlBlur:0,barBlur:1.6,saturate:1.09,brightness:1.035,rim:2.05,rimBoost:2.35,dispersion:.03}
  };
  function buildMap(width,height,profile) {
    width=Math.round(width);height=Math.round(height);
    if(width<32||height<24||width>800||height>240)throw Error('invalid_size');
    const key=width+':'+height+':'+profile;
    if(cache.has(key))return cache.get(key);
    const control=profile==='control';
    const radius=Math.min(width,height)/2,bezel=control?Math.min(18,height*.30):Math.min(24,height*.32),depth=control?26:34;
    const eta=1/1.5,lookup=[];
    let maxShift=0;
    for(let i=0;i<=256;i++){
      const t=Math.max(.001,Math.min(.999,i/256));
      const q=1-Math.pow(1-t,4),h=Math.pow(q,.25);
      const slope=depth/bezel*Math.pow(1-t,3)/Math.pow(q,.75);
      const nz=1/Math.hypot(1,slope),nx=slope*nz;
      const a=Math.sqrt(1-eta*eta*(1-nz*nz))-eta*nz;
      // The small thumb needs a bounded, smooth optical shoulder. With the
      // strongest preset and chromatic offset, .19 * 1.5 * 1.06 * PI < 1:
      // radial source coordinates remain monotonic instead of folding the
      // same glyph into repeated, noisy edge images.
      const shift=control?bezel*.19*Math.sin(Math.PI*t):a*nx*(4+depth*h)/(eta+a*nz);
      lookup.push(shift);maxShift=Math.max(maxShift,shift);
    }
    // Bound the largest displacement, including chromatic separation. During
    // growth this entire coordinate region grows with the actual element.
    const pad=Math.ceil(maxShift*2.05*1.10+8),w=width+pad*2,h=height+pad*2;
    const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
    const ctx=canvas.getContext('2d');if(!ctx)throw Error('canvas_unavailable');
    const pixels=ctx.createImageData(w,h),data=pixels.data;
    const lighting=ctx.createImageData(w,h),rim=lighting.data;
    for(let y=0;y<h;y++)for(let x=0;x<w;x++){
      const p=(y*w+x)*4,px=x-pad+.5,py=y-pad+.5;
      const cx=Math.max(radius,Math.min(width-radius,px));
      const cy=Math.max(radius,Math.min(height-radius,py));
      const vx=px-cx,vy=py-cy,len=Math.hypot(vx,vy),d=radius-len;
      let dx=0,dy=0;
      if(d>=0&&d<bezel&&len>0){
        const t=Math.min(256,d/bezel*256),i=Math.floor(t),f=t-i;
        const shift=lookup[i]*(1-f)+lookup[Math.min(256,i+1)]*f;
        dx=-vx/len*shift/maxShift;dy=-vy/len*shift/maxShift;
      }
      data[p]=Math.round(128+dx*127);data[p+1]=128;
      data[p+2]=Math.round(128+dy*127);data[p+3]=255;
      if(d>=0&&d<bezel&&len>0){
        const falloff=Math.exp(-d/2.4);
        if(control){
          // Encode surface normals, not a baked highlight. Lighting direction
          // is a tiny SVG matrix uniform, updated without rebuilding maps.
          rim[p]=Math.round(128+vx/len*127);rim[p+1]=Math.round(128+vy/len*127);rim[p+2]=128;
          rim[p+3]=Math.round(falloff*94);
        }else{
          const light=-(vx*.6+vy*.8)/len,bright=light>=0,shade=bright?255:30;
          rim[p]=rim[p+1]=rim[p+2]=shade;
          rim[p+3]=Math.round(falloff*(bright?20+58*light*light:8+18*light*light));
        }
      }
    }
    ctx.putImageData(pixels,0,0);
    const uri=canvas.toDataURL('image/png');
    if(!uri.startsWith('data:image/png'))throw Error('map_encode_failed');
    ctx.putImageData(lighting,0,0);const rimUri=canvas.toDataURL('image/png');
    if(!rimUri.startsWith('data:image/png'))throw Error('rim_encode_failed');
    const map={key,uri,rimUri,width,height,pad,maxShift,profile};
    cache.set(key,map);while(cache.size>2)cache.delete(cache.keys().next().value);
    return map;
  }
  function makeFilter(map,id,preset) {
    const svg=document.createElementNS(ns,'svg');
    svg.setAttribute('aria-hidden','true');svg.setAttribute('focusable','false');
    svg.classList.add('liquid-filter-defs');
    // A zero-sized SVG is used, never display:none (which disables references).
    svg.setAttribute('width','0');svg.setAttribute('height','0');
    svg.innerHTML=`<defs><filter id="${id}" filterUnits="objectBoundingBox" primitiveUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceGraphic" stdDeviation="${map.profile==='control'?preset.controlBlur:preset.barBlur}" result="frosted"/>
      <feImage result="map" preserveAspectRatio="none"/>
      <feColorMatrix in="map" type="matrix" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0" result="growthMap" data-growth-map="true"/>
      <feDisplacementMap in="frosted" in2="growthMap" xChannelSelector="R" yChannelSelector="B" result="dispRed" data-channel="red"/>
      <feColorMatrix in="dispRed" type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="red"/>
      <feDisplacementMap in="frosted" in2="growthMap" xChannelSelector="R" yChannelSelector="B" result="dispGreen" data-channel="green"/>
      <feColorMatrix in="dispGreen" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="green"/>
      <feDisplacementMap in="frosted" in2="growthMap" xChannelSelector="R" yChannelSelector="B" result="dispBlue" data-channel="blue"/>
      <feColorMatrix in="dispBlue" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="blue"/>
      <feBlend in="red" in2="green" mode="screen" result="rg"/>
      <feBlend in="rg" in2="blue" mode="screen" result="optical"/>
      <feImage result="rim" preserveAspectRatio="none"/>
      ${map.profile==='control'?'<feColorMatrix in="rim" type="matrix" data-specular-vector="true" result="specularDirection"/><feComposite in="specularDirection" in2="rim" operator="in" result="directionalRim"/>':''}
      <feComponentTransfer in="${map.profile==='control'?'directionalRim':'rim'}" result="rimLit"><feFuncA type="linear" slope="${map.profile==='control'?preset.rim:1.05}"/></feComponentTransfer>
      <feBlend in="rimLit" in2="optical" mode="normal"/>
    </filter></defs>`;
    const filter=svg.querySelector('filter'),images=Array.from(svg.querySelectorAll('feImage'));
    // The outer region follows the element's actual bounds automatically.
    // Primitive/map coordinates remain in pixels, preserving the same optics.
    filter.setAttribute('x',String(-map.pad/map.width));filter.setAttribute('y',String(-map.pad/map.height));
    filter.setAttribute('width',String(1+2*map.pad/map.width));filter.setAttribute('height',String(1+2*map.pad/map.height));
    for(const e of images){
      attr(e,'x',String(-map.pad));attr(e,'y',String(-map.pad));
      attr(e,'width',String(map.width+map.pad*2));
      attr(e,'height',String(map.height+map.pad*2));
    }
    images.forEach((image,i)=>{
      const uri=i===0?map.uri:map.rimUri;
      image.setAttribute('href',uri);image.setAttributeNS('http://www.w3.org/1999/xlink','href',uri);
    });
    return {svg,filter};
  }
  function create(element,opts={}) {
    // Grow geometry by resizing the actual element and this filter's pixel
    // coordinates together. Do not CSS-scale a backdrop-filter layer: that
    // can leave its source region/map at the old size on Android WebView.
    const rect=element.getBoundingClientRect();
    const map=buildMap(opts.width||element.offsetWidth||rect.width,opts.height||element.offsetHeight||rect.height,opts.profile==='control'?'control':'bar');
    const preset=presets[opts.strength]||presets.normal;
    const id='ha-liquid-nav-'+(++serial),refs=makeFilter(map,id,preset);
    const previous=element.style.backdropFilter,previousWebkit=element.style.getPropertyValue('-webkit-backdrop-filter');
    let alive=true,timer=0,images=[],rejectPending=null;
    const strength=map.profile==='control'?preset.control:preset.bar;
    const imagesInFilter=Array.from(refs.filter.querySelectorAll('feImage'));
    const displacement=Array.from(refs.filter.querySelectorAll('feDisplacementMap'));
    const blur=refs.filter.querySelector('feGaussianBlur');
    const rimAlpha=refs.filter.querySelector('feFuncA');
    const specular=refs.filter.querySelector('[data-specular-vector]');
    const growthMap=refs.filter.querySelector('[data-growth-map]');
    let footprint='',lightKey='',engagement=0,lightPower=1;
    function updateRim(){attr(rimAlpha,'slope',map.profile==='control'?(preset.rim+preset.rimBoost*engagement)*lightPower:1.05);}
    function setLighting(angle=-32,power=1,deferRim=false){
      if(!alive||!specular)return;
      angle=Math.max(-150,Math.min(100,Number(angle)||0));power=Math.max(.8,Math.min(1.2,Number(power)||1));
      const key=angle.toFixed(2)+':'+power.toFixed(3);if(key===lightKey)return;lightKey=key;
      const rad=angle*Math.PI/180,lx=Math.sin(rad),ly=-Math.cos(rad),gain=1.8;
      attr(specular,'values','0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  '+(2*lx*gain)+' '+(2*ly*gain)+' 0 0 '+(-(lx+ly)*gain-.7));
      lightPower=power;if(!deferRim)updateRim();
    }
    function resize(scaleX=1,scaleY=scaleX,deferRim=false){
      if(!alive)return;
      scaleX=Math.max(.98,Math.min(1.45,Number(scaleX)||1));scaleY=Math.max(.98,Math.min(1.8,Number(scaleY)||1));
      const next=scaleX.toFixed(5)+':'+scaleY.toFixed(5);if(next===footprint)return;footprint=next;
      for(const e of imagesInFilter){
        attr(e,'x',String(-map.pad*scaleX));attr(e,'y',String(-map.pad*scaleY));
        attr(e,'width',String((map.width+map.pad*2)*scaleX));
        attr(e,'height',String((map.height+map.pad*2)*scaleY));
      }
      const ratio=scaleX/scaleY;
      attr(growthMap,'values',ratio+' 0 0 0 '+(.5*(1-ratio))+'  0 1 0 0 0  0 0 1 0 0  0 0 0 1 0');
      engagement=Math.max(0,Math.min(1,(scaleY-1)/.555));
      // Calm at rest, fuller optics while lifted. This avoids repeated edge
      // images of neighbouring glyphs in the small, settled capsule.
      const opticalGain=map.profile==='control'?.18+.82*engagement:1;
      displacement.forEach((e,i)=>attr(e,'scale',String(2*map.maxShift*strength*(1+i*preset.dispersion)*scaleY*opticalGain)));
      const sigma=map.profile==='control'?preset.controlBlur:preset.barBlur;
      attr(blur,'stdDeviation',(sigma*scaleX)+' '+(sigma*scaleY));
      if(!deferRim)updateRim();
    }
    function update(x,y,angle,power){resize(x,y,true);setLighting(angle,power,true);updateRim();}
    update(1,1,-32,1);
    document.body.appendChild(refs.svg);
    function restore(){element.style.backdropFilter=previous;element.style.setProperty('-webkit-backdrop-filter',previousWebkit);}
    const ready=new Promise((resolve,reject)=>{
      rejectPending=reject;images=[new Image(),new Image()];let loaded=0;
      function end(error){
        clearTimeout(timer);images.forEach(image=>image.onload=image.onerror=null);rejectPending=null;
        if(!alive)return;
        if(error){refs.svg.remove();restore();reject(error);return;}
        const value='url(#'+id+') saturate('+(map.profile==='control'?preset.saturate:1.035)+') brightness('+(map.profile==='control'?preset.brightness:1)+')';
        element.style.backdropFilter=value;element.style.setProperty('-webkit-backdrop-filter',value);
        resolve({id,width:map.width,height:map.height,maxShift:Math.round(map.maxShift*strength*1.07*10)/10,blur:map.profile==='control'?preset.controlBlur:preset.barBlur,brightness:map.profile==='control'?preset.brightness:1,rim:preset.rim});
      }
      timer=setTimeout(()=>end(Error('map_load_timeout')),2500);
      images.forEach((image,i)=>{
        image.onload=()=>{if(++loaded===images.length)end();};
        image.onerror=()=>end(Error(i===0?'map_load_failed':'rim_load_failed'));
        image.src=i===0?map.uri:map.rimUri;
      });
    });
    return {ready,resize,setLighting,update,destroy(){
      if(!alive)return;alive=false;clearTimeout(timer);
      images.forEach(image=>image.onload=image.onerror=null);
      if(rejectPending){rejectPending(Error('cancelled'));rejectPending=null;}
      refs.svg.remove();restore();
    }};
  }
  return {create};
})();
