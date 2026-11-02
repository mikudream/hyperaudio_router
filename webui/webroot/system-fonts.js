"use strict";
// The first paint already uses WebView's current system UI font. Exported
// Android fallback files can contain different Latin glyphs from the active
// theme, so do not insert a loaded FontFace before that working font chain.
window.HASystemFonts = (() => {
  const root=document.documentElement;
  // Remove a legacy inline override once; the stylesheet supplies system-ui.
  root.style.removeProperty('--ha-font');
  function refresh(){root.dataset.fontSource='webview_system';}
  refresh();
  // Keep the app's refresh facade without font exports or asynchronous swaps.
  return {refresh};
})();
