"use strict";
// Apply the saved design system before the first paint. This is separate from
// the system's light/dark preference and from all audio configuration.
(() => {
  let style='miuix';
  try { const value=localStorage.getItem('hyperaudio.ui-style');if(['miuix','md3'].includes(value))style=value; } catch (_) {}
  document.documentElement.dataset.uiStyle=style;
  let floating={miuix:true,md3:false};
  try {const stored=JSON.parse(localStorage.getItem('hyperaudio.floating-nav'))||{};for(const name of ['miuix','md3'])if(typeof stored[name]==='boolean')floating[name]=stored[name];} catch (_) {}
  window.HAFloatingPreferences=floating;
  document.documentElement.dataset.navFloating=String(floating[style]);
})();
