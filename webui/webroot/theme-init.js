// Follow the current WebView preference before paint, then read Android's
// applied system theme. Retire old manual and stale system-theme preferences.
(() => {
  try {localStorage.removeItem('ha-theme');localStorage.removeItem('ha-system-theme');} catch (_) {}
  const media=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)');
  document.documentElement.dataset.theme=media&&media.matches?'dark':'light';
  document.documentElement.dataset.themeMode='system';
  document.documentElement.dataset.themeSource='webview';
  const meta=document.getElementById('page-theme-color');
  if(meta)meta.setAttribute('content',document.documentElement.dataset.theme==='dark'?'#000000':'#f5f6f8');
})();
