"use strict";
// Page scroll positions and title presentation are independent of audio state.
window.HAUI = (() => {
  const pages=['sound','lowlat','settings','about'];
  const views=[...pages,'debug'];
  const titles={sound:'音效链路',lowlat:'低延迟',settings:'设置',about:'关于',debug:'Debug'};
  const root=document.documentElement;
  root.style.setProperty('--ha-nav-count',String(pages.length));
  const large=document.getElementById('pageTitle');
  const compact=document.getElementById('compactTitle');
  const bar=document.getElementById('titleBar');
  const nav=document.querySelector('.bottom-nav');
  let current='sound';
  const positions={sound:0,lowlat:0,settings:0,about:0,debug:0};
  let pendingFrame=0;
  let navFrame=0;
  function measureNavigation() {
    navFrame=0;
    const height=nav.getBoundingClientRect().height;
    if(Number.isFinite(height)&&height>0)root.style.setProperty('--ha-nav-height',Math.ceil(height)+'px');
  }
  function updateNavigationSize() {
    if(!navFrame)navFrame=window.requestAnimationFrame(measureNavigation);
  }
  function paintTitleBar() {
    pendingFrame=0;
    const y=Math.max(0,window.scrollY||0);
    const title=large.getBoundingClientRect();
    const toolbar=bar.getBoundingClientRect();
    // Use live CSS geometry: host inset changes and the active system font can
    // change the threshold. Never store a second guessed status-bar height.
    const progress=title.height>0?Math.max(0,Math.min(1,(toolbar.bottom-title.top)/title.height)):0;
    root.style.setProperty('--ha-expanded-opacity',String(1-progress));
    root.style.setProperty('--ha-compact-opacity',String(progress));
    root.style.setProperty('--ha-bar-opacity',String(Math.min(1,y/20)));
    root.dataset.titleState=progress===0?'expanded':progress===1?'collapsed':'collapsing';
  }
  function updateTitleBar() {
    if(!pendingFrame)pendingFrame=window.requestAnimationFrame(paintTitleBar);
  }
  function show(page) {
    if(!views.includes(page)||page===current)return;
    if(window.HASelectMenus)window.HASelectMenus.close();
    positions[current]=window.scrollY||0;
    current=page;
    views.forEach(name=>{
      document.getElementById('page-'+name).hidden=name!==page;
    });
    const navPage=page==='debug'?'settings':page;
    pages.forEach(name=>{
      const button=document.getElementById('nav-'+name);
      button.classList.toggle('active',name===navPage);
      button.setAttribute('aria-selected',String(name===navPage));
    });
    large.textContent=titles[page];
    compact.textContent=titles[page];
    root.style.setProperty('--ha-nav-index',String(pages.indexOf(navPage)));
    root.dataset.subpage=String(page==='about');
    document.getElementById('btn-about-back').hidden=true;
    document.getElementById('btn-reload').hidden=page==='about';
    window.dispatchEvent(new CustomEvent('ha:page',{detail:{page}}));
    if(window.scrollTo)window.scrollTo({top:positions[page],behavior:'instant'});
    // Apply the new title after the page's saved position has been restored.
    paintTitleBar();
  }
  pages.forEach(page=>document.getElementById('nav-'+page).addEventListener('click',()=>show(page)));
  document.getElementById('btn-about-back').addEventListener('click',()=>show('settings'));
  document.getElementById('btn-debug').addEventListener('click',()=>show('debug'));
  window.addEventListener('scroll',updateTitleBar,{passive:true});
  window.addEventListener('resize',updateTitleBar,{passive:true});
  window.addEventListener('resize',updateNavigationSize,{passive:true});
  if(window.visualViewport)window.visualViewport.addEventListener('resize',updateTitleBar,{passive:true});
  if(window.ResizeObserver){
    const geometryObserver=new ResizeObserver(updateTitleBar);
    geometryObserver.observe(bar);geometryObserver.observe(large);
    const navigationObserver=new ResizeObserver(updateNavigationSize);
    navigationObserver.observe(nav);
  }
  measureNavigation();
  paintTitleBar();
  return {show,current:()=>current,updateTitleBar};
})();
