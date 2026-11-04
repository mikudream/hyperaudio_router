"use strict";
const HELPER = '/system/bin/sh /data/adb/modules/hyperaudio/bin/webui.sh';
let working=false, dirty=false, llLoaded=false, llSaved=null, llTimer=null;
let jobActive=false, pollTimer=null, sequence=0;
let debugEnabled=false, lastReport='', themeTimer=null, themeBusy=false, themeAgain=false;
const $=id=>document.getElementById(id);
const media=window.matchMedia?window.matchMedia('(prefers-color-scheme: dark)'):null;
function saved(key,fallback){try{return localStorage.getItem(key)||fallback;}catch(_){return fallback;}}
function saveLocal(key,value){try{localStorage.setItem(key,value);}catch(_){}}
function toast(text) {
  const t=$('toast'); t.textContent=text; t.hidden=false;
  clearTimeout(toast.timer); toast.timer=setTimeout(()=>{t.hidden=true;},5000);
}
function parse(text) {
  const result={};
  text.split(/\r?\n/).forEach(line=>{const i=line.indexOf('=');if(i>0)result[line.slice(0,i)]=line.slice(i+1);});
  return result;
}
function bridge(command) {
  // 优先同步执行（KernelSU-Next 的 exec(cmd) 直接返回 stdout），
  // 其次命名回调；两者都没有时再报超时。
  try {
    if (window.ksu && typeof window.ksu.exec === 'function') {
      const out = window.ksu.exec(command);
      if (typeof out === 'string' && out) return Promise.resolve(out);
    }
  } catch (e) { }
  return new Promise((resolve,reject)=>{
    if(!window.ksu||typeof window.ksu.exec!=='function') {reject(new Error('未检测到 KernelSU WebUI 接口，请使用模块执行按钮。'));return;}
    const cb='ha_cb_'+Date.now()+'_'+(++sequence);let done=false;
    const timer=setTimeout(()=>finish(new Error('等待返回超时。请查看采集状态或 Download，不要立即重复执行。')),120000);
    function finish(error,value){if(done)return;done=true;clearTimeout(timer);delete window[cb];if(error)reject(error);else resolve(value);}
    window[cb]=(code,out,err)=>{if(!out&&code)finish(new Error(err||('执行失败：'+code)));else finish(null,String(out||''));};
    try {
      window.ksu.exec(command,'{}',cb);
    }catch(e){finish(e);}
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
  ['btn-delay','btn-now'].forEach(id=>{const e=$(id);if(e)e.disabled=working||jobActive;});
  const spin=$('toggleSpin');if(spin)spin.hidden=!working;
  const analyze=$('btn-analyze');if(analyze)analyze.disabled=working||!$('debug-report').value;
  ['btn-save','btn-ll-reset'].forEach(id=>{const e=$(id);if(e)e.disabled=working||!llLoaded;});
  document.querySelectorAll('input, select').forEach(e=>{e.disabled=working;});
  if(window.HASelectMenus)window.HASelectMenus.refresh();
}
async function refreshStatus() {
  const text=await call('status');
  const s=parse(text);
  const st=$('statusText');if(st)st.textContent=text;
  const ov=$('overlayState');if(ov)ov.textContent=s.applied==='native'?'未改写端口与属性':'状态未知';
}
async function refreshTuning() {
  const text=await call('tuning');
  const sources=text.split(/\r?\n/).filter(l=>l.startsWith('source=')).map(l=>l.slice(7));
  const box=$('tuning-src');
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
  const details=$('llDetails');if(details)details.textContent=text;
  const white=(s.whitelist||'').trim();
  const empty=white===''||white==='-';
  const badge=empty?'名单为空':s.ll_state==='verified'?'已生效':s.ll_state==='waiting'?'等待放音':s.ll_state==='no_matching_threads'?'未匹配线程':s.ll_state==='partial'?'部分成功':s.ll_state==='error'?'调度失败':s.ll_state==='suspended'?'已暂停':'调度中';
  $('llBadge').textContent=dirty?'待保存':!live?'后台未就绪':badge;
  const notes={
    verified:'已生效：名单内应用的音频线程已提升到实时优先级。',
    waiting:'等待名单内应用开始放音。',
    no_matching_threads:'名单内应用正在放音，但没有匹配到可提升的音频线程。',
    partial:'部分线程提升失败，详见 Debug 中的低延迟记录。',
    error:'调度失败，详见 Debug 中的低延迟记录。',
    suspended:'调度已暂停。'
  };
  var stateText=$('llStateText');if(stateText)stateText.textContent=empty?'名单为空：不会改动任何系统线程。':(notes[s.ll_state]||'等待调度结果…');
  clearTimeout(llTimer);
  if(!document.hidden)llTimer=setTimeout(()=>{if(!working)refreshLowlat().catch(()=>{});},5000);
}
['f-hal','f-audio','f-app'].forEach(id=>$(id).addEventListener('change',markDirty));
$('btn-ll-reset').addEventListener('click',resetLowlat);
$('btn-save').addEventListener('click',()=>{try{task(collectLowlat());}catch(e){toast(e.message);}});
$('btn-backends').addEventListener('click',()=>task('start-backends'));

async function refreshJob() {
  const data=parse(await call('diag-status'));
  jobActive=data.job==='waiting'||data.job==='collecting';
  const states={idle:'未开始采集',waiting:'后台正在等待目标游戏播放，请切回游戏',collecting:'正在采集，请保持游戏前台',done:'采集完成，日志与摘要已生成',incomplete:'已导出，但现场不足；请查看采集质量',failed:'采集失败，请查看操作记录',stopped:'采集进程已退出，请检查 Download 或重试'};
  $('jobState').textContent=states[data.job]||'采集状态未知';
  $('jobSpin').hidden=!jobActive;
  $('reportPath').textContent=data.report||'诊断包会保存到 Download 文件夹';
  $('reportMode').textContent=data.report_mode||'—';
  $('daemonState').textContent=data.daemon==='ready'?'已运行':'未运行：请启动／重连后台';
  const quality={three_active_samples:'已捕获 3 次目标播放',partial_samples:'部分样本中游戏已停止',target_not_active:'未等到目标游戏播放',mode_changed:'采集中途状态改变，样本不可直接对照',module_disabled:'采集中模块被禁用',system_snapshot:'系统快照：未核对游戏现场'};
  $('captureQuality').textContent=quality[data.quality]||'—';
  if(debugEnabled&&data.report&&data.report!==lastReport&&!jobActive){
    lastReport=data.report;await refreshDebug();
  }
  clearTimeout(pollTimer);
  if(jobActive&&!document.hidden)pollTimer=setTimeout(()=>refreshJob().catch(()=>{}),2500);
  buttons();
}
function operationHint(message){
  if(/未检测到 KernelSU WebUI/.test(message))return '请在支持执行接口的模块 WebUI 管理器中打开。';
  if(/operation_in_progress|scheduler_busy_try_again/.test(message))return '另一个操作正在进行，请稍后重试。';
  if(/scheduler_restore_failed/.test(message))return '低延迟线程还原失败，请查看 Debug。';
  if(/超时/.test(message))return '等待返回超时，请重新读取状态后再操作。';
  return '请重新读取状态，详细原因可在 Debug 查看。';
}
async function task(command) {
  if(working)return false;
  let expected=null;
  if(command.startsWith('ll-save '))expected=command.split(/\s+/).slice(1,4).map(Number);
  working=true;buttons();
  if(command==='diagnose')$('jobState').textContent='正在采集系统快照，请稍候…';
  if(command.startsWith('debug-analyze '))$('debugSummary').textContent='正在本地读取并解读日志…';
  await new Promise(r=>setTimeout(r,0));
  let failed=false;
  try {
    const result=await call(command);
    $('operationResult').textContent=result;
    if(command.startsWith('schedule-diagnose '))toast('后台已接收：切回目标游戏，保持出声场景约 45 秒。');
    else if(command.startsWith('ll-save ')){dirty=false;toast('低延迟设置已保存。');}
    else if(command.startsWith('debug-analyze ')){$('debugSummary').textContent=result;toast('日志解读完成');}
    else if(command!=='diagnose')toast('操作完成');
  } catch(e) {
    failed=true;
    const message=String(e.message||e);
    $('operationResult').textContent=message;
    toast('操作未完成。'+operationHint(message));
    if(command.startsWith('debug-analyze '))$('debugSummary').textContent='解读失败：'+message;
  }
  try {
    await refreshStatus();
    await refreshLowlat();
    await refreshJob();
  }catch(e){failed=true;$('operationResult').textContent+='\n'+e.message;}
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
  try {await refreshStatus();await refreshLowlat();await refreshJob();await refreshTuning();if(debugEnabled)await refreshDebug();}
  catch(e){$('operationResult').textContent=e.message;toast('读取未完成，请查看提示。');}
  working=false;buttons();
}
async function refreshReports(){
  const previous=$('debug-report').value, text=await call('debug-reports'),select=$('debug-report');
  select.textContent='';
  const names=text.split(/\r?\n/).filter(validReport);
  if(!names.length){const o=document.createElement('option');o.value='';o.textContent='暂无诊断包';select.appendChild(o);}
  names.forEach(name=>{const o=document.createElement('option');o.value=name;o.textContent=name;select.appendChild(o);});
  select.value=names.includes(previous)?previous:(names[0]||'');buttons();
}
function validReport(name){return name.length<=100&&/^hyperaudio-(native|sound|compat|unknown)-[0-9]{8}-[0-9]{6}-[0-9]+\.tar\.gz$/.test(name);}
async function refreshDebug(){
  $('debugSummary').textContent=await call('debug-summary');await refreshReports();
}
$('btn-reload').addEventListener('click',()=>{
  dirty=false;
  if(window.HAHostUI&&window.HAHostUI.retry)window.HAHostUI.retry();
  refreshFonts();refreshAll();
});
$('btn-delay').addEventListener('click',()=>{
  const target=$('diagTarget').value.trim();
  if(target.length>200||!/^[_A-Za-z][_A-Za-z0-9]*(\.[_A-Za-z][_A-Za-z0-9]*)+$/.test(target)){
    toast('请填写有效包名，例如 com.ironoakgames.ftk1.mtap');return;
  }
  task('schedule-diagnose '+target);
});
$('btn-now').addEventListener('click',()=>task('diagnose'));
$('btn-job-refresh').addEventListener('click',()=>refreshJob().then(()=>refreshDebug()).catch(e=>toast(e.message)));
$('btn-reports').addEventListener('click',()=>refreshReports().catch(e=>toast(e.message)));
$('debug-report').addEventListener('change',buttons);
$('btn-analyze').addEventListener('click',()=>{
  const name=$('debug-report').value;
  if(!validReport(name)){toast('请先选择有效诊断包');return;}
  task('debug-analyze '+name);
});
$('debug-enable').addEventListener('change',()=>{
  debugEnabled=$('debug-enable').checked;
  saveLocal('ha-debug',debugEnabled?'1':'0');
  $('debugPanel').hidden=!debugEnabled;
  if(debugEnabled)refreshDebug().catch(e=>toast(e.message));
});
function applyTheme(theme,source){
  const root=document.documentElement,changed=root.dataset.theme!==theme,nextSource=source||'webview';
  const sourceChanged=root.dataset.themeSource!==nextSource;
  root.dataset.theme=theme;
  root.dataset.themeMode='system';
  root.dataset.themeSource=nextSource;
  if(changed){
    $('page-theme-color').setAttribute('content',theme==='dark'?'#000000':'#f5f6f8');
    if(window.HAHostUI)window.HAHostUI.refresh();
  }else if(window.HAHostUI){
    if(window.HAHostUI.checkTheme)window.HAHostUI.checkTheme();
    if(sourceChanged&&window.HAHostUI.refreshDiagnostics)window.HAHostUI.refreshDiagnostics();
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
  else {clearTimeout(pollTimer);clearTimeout(llTimer);clearTimeout(themeTimer);}
});
debugEnabled=saved('ha-debug','0')==='1';
$('debug-enable').checked=debugEnabled;
$('debugPanel').hidden=!debugEnabled;
applyTheme(themeFallback(),'webview');
refreshTheme();refreshFonts();refreshAll();
