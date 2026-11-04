"use strict";
const HELPER = '/system/bin/sh /data/adb/modules/hyperaudio/bin/webui.sh';
let working=false, dirty=false, llLoaded=false, llSaved=null, llTimer=null;
let sequence=0, themeTimer=null, themeBusy=false, themeAgain=false;
const $=id=>document.getElementById(id);
const media=window.matchMedia?window.matchMedia('(prefers-color-scheme: dark)'):null;
function saved(key,fallback){try{return localStorage.getItem(key)||fallback;}catch(_){return fallback;}}
function toast(text) {
  const t=$('toast'); if(!t)return;
  t.textContent=text; t.hidden=false;
  clearTimeout(toast.timer); toast.timer=setTimeout(()=>{t.hidden=true;},5000);
}
function parse(text) {
  const result={};
  text.split(/\r?\n/).forEach(line=>{const i=line.indexOf('=');if(i>0)result[line.slice(0,i)]=line.slice(i+1);});
  return result;
}
function bridge(command) {
  try {
    if (window.ksu && typeof window.ksu.exec === 'function') {
      const out = window.ksu.exec(command);
      if (typeof out === 'string' && out) return Promise.resolve(out);
    }
  } catch (e) { }
  return new Promise((resolve,reject)=>{
    if(!window.ksu||typeof window.ksu.exec!=='function') {reject(new Error('未检测到 KernelSU WebUI 接口，请使用模块执行按钮。'));return;}
    const cb='ha_cb_'+Date.now()+'_'+(++sequence);let done=false;
    const timer=setTimeout(()=>finish(new Error('等待返回超时，请重新读取状态。')),30000);
    function finish(error,value){if(done)return;done=true;clearTimeout(timer);delete window[cb];if(error)reject(error);else resolve(value);}
    window[cb]=(code,out,err)=>{if(!out&&code)finish(new Error(err||('执行失败：'+code)));else finish(null,String(out||''));};
    try { window.ksu.exec(command,'{}',cb); } catch(e){finish(e);}
  });
}
async function call(args) {
  const raw=await bridge(HELPER+' '+args);
  const line=raw.trim().split(/\r?\n/).pop();
  const m=/^rc=(\d+)\|([A-Za-z0-9+/=]*)$/.exec(line);
  if(!m)throw new Error('返回格式异常：'+raw);
  const text=new TextDecoder('utf-8').decode(Uint8Array.from(atob(m[2]),c=>c.charCodeAt(0)));
  if(m[1]!=='0')throw new Error(text);
  return text;
}
function buttons() {
  document.querySelectorAll('button').forEach(b=>{b.disabled=working;});
  ['btn-save','btn-ll-reset'].forEach(id=>{const e=$(id);if(e)e.disabled=working||!llLoaded;});
  document.querySelectorAll('input, select').forEach(e=>{e.disabled=working;});
  if(window.HASelectMenus)window.HASelectMenus.refresh();
}
async function refreshTuning() {
  const text=await call('tuning');
  const sources=text.split(/\r?\n/).filter(l=>l.startsWith('source=')).map(l=>l.slice(7));
  const box=$('tuning-src'); if(!box)return;
  box.textContent=sources.length?sources.join('\n'):'未发现已启用的调音模块';
  box.style.whiteSpace='pre-line';
}
function markDirty(){
  dirty=true;
  $('dirtyNote').hidden=false;
  $('llBadge').textContent='待保存';
}
function setLowlatFields(config){
  $('f-hal').value=config.hal_priority;
  $('f-audio').value=config.audio_priority;
  $('f-app').value=config.app_priority;
  $('dirtyNote').hidden=true;
}
function resetLowlat(){
  if(working||!llLoaded)return;
  dirty=false;
  task('ll-save 20 16 15').then(ok=>{if(ok)toast('低延迟设置已恢复默认。');});
}
function collectLowlat(){
  const values=['f-hal','f-audio','f-app'].map(id=>$(id).value.trim());
  if(values.some(x=>!/^([1-9]|[1-9][0-9])$/.test(x)))throw new Error('优先级必须是 1–99 的整数');
  return "ll-save "+values.join(' ');
}
async function refreshLowlat(){
  const text=await call('ll-status');
  const s=parse(text.split('proof_begin')[0].split('current_details_begin')[0]);
  llLoaded=['hal_priority','audio_priority','app_priority'].every(k=>/^([1-9]|[1-9][0-9])$/.test(s[k]||''));
  if(!llLoaded)throw new Error('未取得完整的低延迟配置，请重新读取。');
  llSaved={hal_priority:s.hal_priority,audio_priority:s.audio_priority,app_priority:s.app_priority};
  if(!dirty)setLowlatFields(llSaved);
  const live=s.ll_daemon==='running'&&Number(s.ll_age)<=20;
  const white=(s.whitelist||'').trim();
  const empty=white===''||white==='-';
  const badge=empty?'':s.ll_state==='verified'?'已生效':s.ll_state==='waiting'?'等待放音':s.ll_state==='no_matching_threads'?'未匹配线程':s.ll_state==='partial'?'部分成功':s.ll_state==='error'?'调度失败':s.ll_state==='suspended'?'已暂停':'调度中';
  const badgeEl=$('llBadge');
  badgeEl.textContent=dirty?'待保存':!live?'后台未就绪':badge;
  badgeEl.hidden=(empty && !dirty);
  badgeEl.style.display=(empty && !dirty)?'none':'';
  const notes={
    verified:'已生效：名单内应用的音频线程已提升到实时优先级。',
    waiting:'等待名单内应用开始放音。',
    no_matching_threads:'名单内应用正在放音，但没有匹配到可提升的音频线程。',
    partial:'部分线程提升失败，请稍后重试。',
    error:'调度失败，请稍后重试。',
    suspended:'调度已暂停。'
  };
  const stateText=$('llStateText');
  if(stateText){ stateText.textContent=empty?'':(notes[s.ll_state]||'等待调度结果…'); stateText.hidden=empty; stateText.style.display=empty?'none':''; }
  clearTimeout(llTimer);
  if(!document.hidden)llTimer=setTimeout(()=>{if(!working)refreshLowlat().catch(()=>{});},5000);
}
['f-hal','f-audio','f-app'].forEach(id=>$(id).addEventListener('change',markDirty));
$('btn-ll-reset').addEventListener('click',resetLowlat);
$('btn-save').addEventListener('click',()=>{try{task(collectLowlat());}catch(e){toast(e.message);}});
async function task(command) {
  if(working)return false;
  let expected=null;
  if(command.startsWith('ll-save '))expected=command.split(/\s+/).slice(1,4).map(Number);
  working=true;buttons();
  await new Promise(r=>setTimeout(r,0));
  let failed=false;
  try {
    await call(command);
    if(command.startsWith('ll-save ')){dirty=false;toast('低延迟设置已保存。');}
  } catch(e) {
    failed=true;
    toast('操作未完成。'+(String(e.message||e)));
  }
  try { await refreshLowlat(); } catch(e){failed=true;}
  if(expected&&!failed){
    const actual=[Number(llSaved.hal_priority),Number(llSaved.audio_priority),Number(llSaved.app_priority)];
    if(expected.some((value,i)=>value!==actual[i])){failed=true;toast('无法确认设置已应用，请重新读取。');}
  }
  working=false;buttons();
  return !failed;
}
async function refreshAll() {
  if(working)return;
  working=true;buttons();
  try { await refreshLowlat(); await refreshTuning(); }
  catch(e){ toast('读取未完成，请重试。'); }
  working=false;buttons();
}
$('btn-reload').addEventListener('click',()=>{
  dirty=false;
  if(window.HAHostUI&&window.HAHostUI.retry)window.HAHostUI.retry();
  refreshFonts();refreshAll();
});
function applyTheme(theme,source){
  const root=document.documentElement,changed=root.dataset.theme!==theme,nextSource=source||'webview';
  root.dataset.theme=theme;
  root.dataset.themeMode='system';
  root.dataset.themeSource=nextSource;
  if(changed){
    $('page-theme-color').setAttribute('content',theme==='dark'?'#000000':'#f5f6f8');
    if(window.HAHostUI)window.HAHostUI.refresh();
  }else if(window.HAHostUI&&window.HAHostUI.checkTheme){
    window.HAHostUI.checkTheme();
  }
}
function themeFallback(){return media&&media.matches?'dark':'light';}
function refreshFonts(){if(window.HASystemFonts)window.HASystemFonts.refresh();}
async function refreshTheme(){
  clearTimeout(themeTimer);
  if(themeBusy){themeAgain=true;return;}
  themeBusy=true;themeAgain=false;
  try{
    const s=parse(await call('theme'));
    if(['light','dark'].includes(s.theme))applyTheme(s.theme,s.source);
    else applyTheme(themeFallback(),'webview');
  }catch(_){applyTheme(themeFallback(),'webview');}
  finally{themeBusy=false;if(!document.hidden)themeTimer=setTimeout(refreshTheme,themeAgain?0:10000);}
}
if(media){const listener=()=>{applyTheme(themeFallback(),'webview');refreshTheme();};if(media.addEventListener)media.addEventListener('change',listener);else if(media.addListener)media.addListener(listener);}
document.addEventListener('visibilitychange',()=>{
  if(!document.hidden){refreshTheme();refreshFonts();if(!working)refreshAll();}
  else {clearTimeout(llTimer);clearTimeout(themeTimer);}
});
applyTheme(themeFallback(),'webview');
refreshTheme();refreshFonts();refreshAll();
