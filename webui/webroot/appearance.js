"use strict";
(() => {
  const root=document.documentElement,select=document.getElementById('ui-style');
  const miuix=document.getElementById('miuix-bottom-settings');
  const material=document.getElementById('md3-bottom-settings');
  const floating=document.getElementById('floating-nav');
  const preferences=window.HAFloatingPreferences||{miuix:true,md3:false};
  function sync(){
    const style=root.dataset.uiStyle==='md3'?'md3':'miuix';
    select.value=style;
    floating.checked=preferences[style];
    root.dataset.navFloating=String(floating.checked);
    miuix.hidden=style!=='miuix'||!floating.checked;
    material.hidden=style!=='md3'||!floating.checked;
    if(window.HASelectMenus)window.HASelectMenus.refresh('ui-style');
    if(window.HAUI)window.HAUI.updateTitleBar();
  }
  select.addEventListener('change',()=>{
    const value=select.value==='md3'?'md3':'miuix';
    if(window.HASelectMenus)window.HASelectMenus.close();
    document.querySelector('.bottom-nav').dispatchEvent(new Event('ha:nav-reset'));
    root.dataset.uiStyle=value;
    try {localStorage.setItem('hyperaudio.ui-style',value);} catch (_) {}
    sync();window.dispatchEvent(new Event('ha:appearance'));
  });
  floating.addEventListener('change',()=>{
    const style=root.dataset.uiStyle==='md3'?'md3':'miuix';
    document.querySelector('.bottom-nav').dispatchEvent(new Event('ha:nav-reset'));
    preferences[style]=floating.checked;
    try {localStorage.setItem('hyperaudio.floating-nav',JSON.stringify(preferences));} catch (_) {}
    sync();window.dispatchEvent(new Event('ha:appearance'));
  });
  sync();
})();
