"use strict";
const HELPER = '/system/bin/sh /data/adb/modules/hyperaudio/bin/webui.sh';
const LABELS = {native:'原生模式',compat:'兼容模式',sound:'音效模式'};
const SOUND_IDS=['s-custom','s-mmap','s-fast','s-fast-raw','s-raw'];
const DESCRIPTIONS = {
  native:'使用系统原有的播放方式，可按需开启低延迟调度。',
  sound:'尝试让更多游戏和应用使用系统或调音模块提供的音效。实际效果因应用而异，切换后请重新打开游戏。'
};
let currentMode='native', dirty=false, bootDirty=false, llTimer=null;
let llLoaded=false, llSaved=null;
let soundDirty=false, soundLoaded=false, soundPanelOpen=false, soundState='saved', soundValid=true;
let soundSaved=null;
let sequence=0, working=false, jobActive=false, pollTimer=null;
const $=id=>document.getElementById(id);
let debugEnabled=false, lastReport='', themeTimer=null, themeBusy=false, themeAgain=false;
const media=window.matchMedia?window.matchMedia('(prefers-color-scheme: dark)'):null;
function saved(key,fallback){try{return localStorage.getItem(key)||fallback;}catch(_){return fallback;}}
function saveLocal(key,value){try{localStorage.setItem(key,value);}catch(_){}}
function toast(text) {
  $('toast').textContent=text; $('toast').hidden=false;
  clearTimeout(toast.timer); toast.timer=setTimeout(()=>{$('toast').hidden=true;},5000);
}
function parse(text) {
  const result={};
  text.split(/\r?\n/).forEach(line=>{const i=line.indexOf('=');if(i>0)result[line.slice(0,i)]=line.slice(i+1);});
  return result;
}
function bridge(command) {
  return new Promise((resolve,reject)=>{
    if(!window.ksu||typeof window.ksu.exec!=='function') {reject(new Error('未检测到 KernelSU WebUI 接口，请使用模块执行按钮。'));return;}
    const cb='ha_cb_'+Date.now()+'_'+(++sequence);let done=false;
    const timer=setTimeout(()=>finish(new Error('等待返回超时。请查看采集状态或 Download，不要立即重复执行。')),120000);
    function finish(error,value){if(done)return;done=true;clearTimeout(timer);delete window[cb];if(error)reject(error);else resolve(value);}
    window[cb]=(code,out,err)=>{if(!out&&code)finish(new Error(err||('执行失败：'+code)));else finish(null,String(out||''));};
    try {
      // A mutation is issued once only, regardless of callback / sync / Promise bridge.
      const ret=window.ksu.exec(command,'{}',cb);
      if(typeof ret==='string'&&ret)finish(null,ret);
      else if(ret&&typeof ret.then==='function')ret.then(v=>finish(null,typeof v==='string'?v:String(v.stdout||'')),e=>finish(e));
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
  $('btn-delay').disabled=working||jobActive;
  $('btn-now').disabled=working||jobActive;
  $('toggleSpin').hidden=!working;
  $('btn-analyze').disabled=working||!$('debug-report').value;
  $('btn-save').disabled=working||!llLoaded||currentMode!=='native';
  $('btn-ll-reset').disabled=working||!llLoaded||currentMode!=='native';
  $('f-enable').disabled=working||!llLoaded||currentMode!=='native';
  $('btn-sound-save').disabled=working||!soundLoaded||!soundValid;
  $('btn-sound-save').textContent=currentMode==='sound'?'保存并应用':'保存配置';
  document.querySelectorAll('input, select').forEach(e=>{e.disabled=working;});
  $('f-enable').disabled=working||!llLoaded||currentMode!=='native';
  $('s-custom').disabled=working||!soundLoaded;
  SOUND_IDS.slice(1).forEach(id=>{$(id).disabled=working||!soundLoaded||!soundValid;});
  if(window.HASelectMenus)window.HASelectMenus.refresh();
}
async function refreshStatus() {
  const text=await call('status'),s=parse(text);
  $('statusText').textContent=text;
  currentMode=s.applied;
  const label=LABELS[s.applied]||'状态未知';
  $('runBadge').textContent=['native','sound'].includes(s.applied)?'已应用':'状态未知';
  $('currentMode').textContent=label;
  $('modeDesc').textContent=DESCRIPTIONS[s.applied]||'无法读取当前模式，请重新读取。';
  $('overlayState').textContent={none:'未覆盖',owned:'已应用模块配置',conflict:'检测到覆盖冲突'}[s.overlay]||'未知';
  document.querySelectorAll('[data-mode]').forEach(b=>{b.classList.toggle('active',b.dataset.mode===s.applied);b.setAttribute('aria-pressed',String(b.dataset.mode===s.applied));});
  $('sub').textContent='音频模式热切换';
  $('card-fast').hidden=s.applied!=='native';
  $('soundWarning').hidden=s.applied!=='sound';
  if(s.applied==='sound'||(s.boot_mode==='sound'&&s.boot_guard&&s.boot_guard!=='none'))soundPanelOpen=true;
  $('soundSettings').hidden=s.applied!=='sound'&&!soundPanelOpen;
  $('soundRecoveryHint').hidden=s.applied==='sound';
  const bootMode=['native','sound'].includes(s.boot_mode)?s.boot_mode:'native';
  $('bootSaved').textContent=s.boot_config==='invalid'?'配置异常，请重新保存':LABELS[bootMode];
  if(!bootDirty)$('boot-mode').value=bootMode;
  renderBootChoice();
  const guarded=s.boot_guard&&s.boot_guard!=='none';
  $('bootGuard').hidden=!guarded;
  $('bootGuard').textContent=guarded?'上次启动或切换出现异常，开机暂时使用原生模式并暂停低延迟，已保存的设置会保留。排查后重新保存开机设置，即可再次启用。':'';
}
async function refreshTuning() {
  const text=await call('tuning');
  const sources=text.split(/\r?\n/).filter(l=>l.startsWith('source=')).map(l=>l.slice(7));
  $('tuning-src').textContent=sources.length?sources.join('\n'):'未发现已启用的调音模块';
  $('tuning-src').style.whiteSpace='pre-line';
}
function renderSound() {
  const custom=$('s-custom').checked;
  $('soundControls').hidden=!custom;
  $('soundUnrestricted').hidden=!custom||SOUND_IDS.slice(1).some(id=>$(id).checked);
  $('soundBadge').textContent=soundDirty?'待保存':!soundValid?'配置异常':custom?'自定义配置':'默认配置';
  $('soundDirtyNote').hidden=!soundDirty;
  const states={invalid:'设置异常，请打开“自定义音频设置”并点“恢复默认”。',mismatch:'无法确认设置是否已应用，请重新读取或恢复默认。',recovery_required:'上次恢复未完成，请在设置中点“恢复原生配置”。'};
  $('soundApplyState').textContent=states[soundState]||'无法确认设置是否已应用，请重新读取。';
  $('soundApplyState').hidden=['applied','saved'].includes(soundState)||soundDirty;
  if(currentMode==='sound')$('runBadge').textContent=soundState==='applied'?'已应用':'待确认';
}
async function refreshSound() {
  const s=parse(await call('sound-status'));
  soundLoaded=['sound_custom','sound_mmap','sound_fast','sound_fast_raw','sound_raw'].every(k=>/^[01]$/.test(s[k]||''));
  soundValid=soundLoaded&&s.sound_config!=='invalid';soundState=s.sound_state;
  if(!soundLoaded)throw new Error('未取得完整音效配置，请重新读取。');
  soundSaved=['sound_custom','sound_mmap','sound_fast','sound_fast_raw','sound_raw'].map(k=>s[k]);
  if(!soundDirty)setSoundFields(soundSaved);
  if(!soundValid)soundPanelOpen=true;
  $('soundSettings').hidden=currentMode!=='sound'&&!soundPanelOpen;
  renderSound();buttons();
}
function markSoundDirty(){soundDirty=true;renderSound();}
function setSoundFields(config){SOUND_IDS.forEach((id,i)=>{$(id).checked=config[i]==='1';});}
function changeSoundCustom(){
  if(working||!soundLoaded)return;
  if(!soundValid){renderSound();return;}
  if($('s-custom').checked){markSoundDirty();return;}
  // Cancelling an unsaved expansion keeps the saved values without a root call.
  if(soundSaved[0]==='0'){soundDirty=false;setSoundFields(soundSaved);renderSound();return;}
  renderSound();saveSound(false,true);
}
function collectSound(){return 'sound-save '+SOUND_IDS.map(id=>$(id).checked?'1':'0').join(' ');}
async function saveSound(reset=false,disableCustom=false){
  if(working||(!reset&&(!soundLoaded||!soundValid)))return;
  const applying=currentMode==='sound';working=true;buttons();
  $('soundApplyState').textContent=applying?'正在应用设置并等待音频服务恢复…':'正在保存音效配置…';
  $('soundApplyState').hidden=false;
  let completed=false;
  try{
    const command=reset?'sound-reset':disableCustom?'sound-save 0 '+soundSaved.slice(1).join(' '):collectSound();
    const result=await call(command);$('operationResult').textContent=result;completed=true;soundDirty=false;
    await refreshStatus();await refreshSound();await refreshLowlat();
    if(applying&&soundState!=='applied')throw new Error('无法确认设置是否已应用，请重新读取或恢复默认。');
    toast(applying?'音效设置已应用，请强行停止并重新打开游戏。':'音效设置已保存，切换到音效模式时生效。');
  }catch(e){
    const message=String(e.message||e);$('operationResult').textContent=message;
    if(disableCustom){soundDirty=false;setSoundFields(soundSaved);renderSound();}
    try{await refreshStatus();await refreshSound();await refreshLowlat();}catch(_){}
    let hint='请重新读取状态或恢复默认配置。';
    if(completed)hint='无法确认设置是否已应用，请重新读取。';
    else if(/apply_failed_restored_native|sound_config_save_failed_restored_native/.test(message))hint='已恢复原生模式，之前保存的音效配置保留。';
    else if(/reboot_required/.test(message))hint='音频恢复尚未完成，请重启手机后检查当前模式。';
    else if(/operation_in_progress|scheduler_busy_try_again/.test(message))hint='另一个操作正在进行，请稍后重试。';
    else if(/scheduler_restore_failed/.test(message))hint='低延迟调度恢复失败，未应用新音效配置。';
    $('soundApplyState').textContent='操作未完成：'+hint;
    $('soundApplyState').hidden=false;
    toast('音效配置未完成，请查看提示。');
  }
  working=false;buttons();
}
async function refreshJob() {
  const data=parse(await call('diag-status'));
  jobActive=data.job==='waiting'||data.job==='collecting';
  const states={idle:'未开始采集',waiting:'后台正在等待目标游戏播放，请切回游戏',collecting:'正在采集，请保持游戏前台',done:'采集完成，日志与摘要已生成',incomplete:'已导出，但现场不足或模式改变；请查看采集质量',failed:'采集失败，请查看操作记录',stopped:'采集进程已退出，请检查 Download 或重试'};
  $('jobState').textContent=states[data.job]||'采集状态未知';
  $('jobSpin').hidden=!jobActive;
  $('reportPath').textContent=data.report||'诊断包会保存到 Download 文件夹';
  $('reportMode').textContent=LABELS[data.report_mode]||'—';
  $('daemonState').textContent=data.daemon==='ready'?'已运行':'未运行：请启动／重连后台';
  const quality={three_active_samples:'已捕获 3 次目标播放',partial_samples:'部分样本中游戏已停止',target_not_active:'未等到目标游戏播放',mode_changed:'采集中途切档，样本不可直接对照',module_disabled:'采集中模块被禁用',system_snapshot:'系统快照：未核对游戏现场'};
  $('captureQuality').textContent=quality[data.quality]||'—';
  if(debugEnabled&&data.report&&data.report!==lastReport&&!jobActive){
    lastReport=data.report;await refreshDebug();
  }
  clearTimeout(pollTimer);
  if(jobActive&&!document.hidden)pollTimer=setTimeout(()=>refreshJob().catch(()=>{}),2500);
  buttons();
}
function modeMessage(text,state){
  clearTimeout(modeMessage.timer);
  $('modeMsg').textContent=text;$('modeMsg').dataset.state=state;$('modeMsg').hidden=false;
  if(state==='success')modeMessage.timer=setTimeout(()=>{$('modeMsg').hidden=true;},6000);
}
function operationHint(message){
  if(/未检测到 KernelSU WebUI/.test(message))return '请在支持执行接口的模块 WebUI 管理器中打开。';
  if(/apply_failed_restored_native|sound_config_save_failed_restored_native/.test(message))return '已退回原生模式，已保存的配置保留。';
  if(/operation_in_progress|scheduler_busy_try_again/.test(message))return '另一个操作正在进行，请稍后重试。';
  if(/scheduler_restore_failed/.test(message))return '低延迟调度还原失败，请查看 Debug。';
  if(/reboot_required/.test(message))return '音频恢复未完成，请重启手机后检查。';
  if(/超时/.test(message))return '等待返回超时，请重新读取状态后再操作。';
  return '请重新读取状态，详细原因可在 Debug 查看。';
}
async function task(command) {
  if(working)return;
  const switching=command.startsWith('apply ')||command==='recover';
  const target=command==='recover'?'native':command.slice(6);
  const label=LABELS[target]||'所选模式';
  working=true;buttons();
  if(switching)modeMessage('正在切换到'+label+'，声音可能短暂中断…','busy');
  if(command==='diagnose')$('jobState').textContent='正在采集系统快照，请稍候…';
  if(command.startsWith('debug-analyze '))$('debugSummary').textContent='正在本地读取并解读日志…';
  await new Promise(r=>setTimeout(r,0));
  let result='',failed=false;
  try {
    result=await call(command);$('operationResult').textContent=result;
    if(command.startsWith('schedule-diagnose '))toast('后台已接收：切回目标游戏，保持出声场景约 45 秒。');
    else if(command.startsWith('ll-save ')){dirty=false;}
    else if(command.startsWith('boot-save ')){bootDirty=false;toast('开机设置已保存，当前模式不变。');}
    else if(command.startsWith('debug-analyze ')){$('debugSummary').textContent=result;toast('日志解读完成');}
    else if(!switching)toast('操作完成');
  } catch(e) {
    failed=true;
    const message=String(e.message||e);$('operationResult').textContent=message;
    modeMessage((switching?'切换未完成。':'操作未完成。')+operationHint(message),'error');
    if(command.startsWith('debug-analyze '))$('debugSummary').textContent='解读失败：'+message;
    toast('操作失败，请查看提示');
  }
  try {
    await refreshStatus();await refreshSound();await refreshLowlat();await refreshJob();
    if(command.startsWith('ll-save ')&&!failed){
  const actual=['enabled','hal_priority','audio_priority','app_priority'].map(k=>llSaved[k]);
      if(expected.some((value,i)=>value!==actual[i])){failed=true;modeMessage('无法确认设置是否已应用，请重新读取或恢复默认。','error');toast('无法确认设置是否已应用，请查看提示。');}
      else toast('低延迟设置已保存。');
    }
    if(switching&&!failed){
      if(currentMode!==target||(target==='sound'&&soundState!=='applied')){failed=true;modeMessage('无法确认是否已切换，请重新读取或恢复原生。','error');}
      else {
        modeMessage(command==='recover'?'已恢复原生配置，开机模式也已设为原生。':'已切换至'+label+'，请重新打开游戏。','success');
        toast('已切换至'+label+'，请重新打开游戏。');
      }
    }
  }catch(e){failed=true;$('operationResult').textContent+='\n'+e.message;modeMessage('读取结果失败，请重新读取状态。','error');}
  working=false;buttons();
  return !failed;
}
async function refreshAll() {
  if(working)return;
  working=true;buttons();
  try {await refreshStatus();await refreshSound();await refreshLowlat();await refreshJob();await refreshTuning();if(debugEnabled)await refreshDebug();}
  catch(e){$('operationResult').textContent=e.message;$('runBadge').textContent='读取失败';modeMessage('读取未完成。'+operationHint(String(e.message||e)),'error');toast('读取未完成，请查看提示。');}
  working=false;buttons();
}
function validPackage(s){return s.length<=200&&/^[_A-Za-z][_A-Za-z0-9]*(\.[_A-Za-z][_A-Za-z0-9]*)+$/.test(s);}
function markDirty(){dirty=true;$('dirtyNote').hidden=false;$('llBadge').textContent='待保存';$('llControls').hidden=!$('f-enable').checked;}
function setLowlatFields(config){
  $('f-enable').checked=config.enabled==='1';
  $('f-hal').value=config.hal_priority;$('f-audio').value=config.audio_priority;$('f-app').value=config.app_priority;
  $('dirtyNote').hidden=true;$('llControls').hidden=!$('f-enable').checked;
}
function changeLowlatEnable(){
  if(working||!llLoaded)return;
  if($('f-enable').checked){markDirty();return;}
  dirty=false;
  if(llSaved.enabled==='0'){setLowlatFields(llSaved);$('llBadge').textContent='关闭';return;}
  // Stop with saved values, so closing cannot commit unsaved parameter edits.
  const command='ll-save 0 '+[llSaved.hal_priority,llSaved.audio_priority,llSaved.app_priority].join(' ');
  setLowlatFields({...llSaved,enabled:'0'});task(command);
}
function resetLowlat(){
  if(working||!llLoaded||currentMode!=='native')return;
  dirty=false;
  task('ll-save 0 20 16 15').then(ok=>{if(ok)toast('低延迟设置已恢复默认。');});
}
function collectLowlat(){
  const values=['f-hal','f-audio','f-app'].map(id=>$(id).value.trim());
  if(values.some(x=>!/^([1-9]|[1-9][0-9])$/.test(x)))throw new Error('优先级必须是 1–99 的整数');
  return "ll-save "+[$('f-enable').checked?'1':'0',...values].join(' ');
}
async function refreshLowlat(){
  const text=await call('ll-status'),s=parse(text.split('proof_begin')[0].split('current_details_begin')[0]);
  llLoaded=/^[01]$/.test(s.enabled||'')&&['hal_priority','audio_priority','app_priority'].every(k=>/^([1-9]|[1-9][0-9])$/.test(s[k]||''));
  if(!llLoaded)throw new Error('未取得完整的低延迟配置，请重新读取。');
  llSaved={enabled:s.enabled,hal_priority:s.hal_priority,audio_priority:s.audio_priority,app_priority:s.app_priority};
  if(!dirty){
    setLowlatFields(llSaved);
  }
  const live=s.ll_daemon==='running'&&Number(s.ll_age)<=20;
  $('llDetails').textContent=text;
  const active=s.enabled==='1';
  $('llBadge').textContent=dirty?'待保存':!active?'关闭':currentMode==='sound'?'音效模式下暂停':s.ll_state==='suspended'?'已暂停 · 见开机提示':!live?'后台未就绪':s.ll_state==='error'?'应用失败 · 见 Debug':s.ll_state==='partial'?'部分应用 · 见 Debug':'已开启';
  clearTimeout(llTimer);
  if(!document.hidden)llTimer=setTimeout(()=>{if(!working)refreshLowlat().catch(()=>{});},5000);
}
['f-hal','f-audio','f-app'].forEach(id=>$(id).addEventListener('change',markDirty));
$('f-enable').addEventListener('change',changeLowlatEnable);
$('btn-ll-reset').addEventListener('click',resetLowlat);
$('s-custom').addEventListener('change',changeSoundCustom);
SOUND_IDS.slice(1).forEach(id=>$(id).addEventListener('change',markSoundDirty));
$('btn-sound-save').addEventListener('click',()=>saveSound());
$('btn-sound-reset').addEventListener('click',()=>saveSound(true));
$('btn-save').addEventListener('click',()=>{try{task(collectLowlat());}catch(e){toast(e.message);}});
function renderBootChoice(){
  const sound=$('boot-mode').value==='sound';
  $('bootDesc').textContent=sound?'开机时使用已保存的音效设置，低延迟调度暂停。':'开机时使用已保存的低延迟设置。';
  $('bootWarning').hidden=!sound;
  if(window.HASelectMenus)window.HASelectMenus.refresh('boot-mode');
}
$('boot-mode').addEventListener('change',()=>{bootDirty=true;renderBootChoice();});
$('btn-boot-save').addEventListener('click',()=>{
  const mode=$('boot-mode').value;
  if(!['native','sound'].includes(mode)){toast('请选择原生或音效模式');return;}
  task('boot-save '+mode);
});
$('btn-backends').addEventListener('click',()=>task('start-backends'));
$('btn-native').addEventListener('click',()=>{dirty=false;bootDirty=false;soundPanelOpen=false;if(window.HAUI)window.HAUI.show('mode');task('recover');});
document.querySelectorAll('[data-mode]').forEach(b=>b.addEventListener('click',()=>{
  if(currentMode===b.dataset.mode&&(currentMode==='native'||soundState==='applied')){toast('当前已是'+LABELS[currentMode]);return;}
  soundPanelOpen=b.dataset.mode==='sound';task('apply '+b.dataset.mode);
}));
$('btn-reload').addEventListener('click',()=>{dirty=false;bootDirty=false;soundDirty=false;if(window.HAHostUI&&window.HAHostUI.retry)window.HAHostUI.retry();refreshFonts();refreshAll();});
$('btn-delay').addEventListener('click',()=>{
  const target=$('diagTarget').value.trim();
  if(target.length>200||!/^[_A-Za-z][_A-Za-z0-9]*(\.[_A-Za-z][_A-Za-z0-9]*)+$/.test(target)){
    toast('请填写有效包名，例如 com.ironoakgames.ftk1.mtap');return;
  }
  task('schedule-diagnose '+target);
});
$('btn-now').addEventListener('click',()=>task('diagnose'));
$('btn-job-refresh').addEventListener('click',()=>refreshJob().then(()=>refreshDebug()).catch(e=>toast(e.message)));
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
$('debug-enable').addEventListener('change',()=>{
  debugEnabled=$('debug-enable').checked;saveLocal('ha-debug',debugEnabled?'1':'0');$('debugPanel').hidden=!debugEnabled;
  if(debugEnabled)refreshDebug().catch(e=>toast(e.message));
});
$('btn-reports').addEventListener('click',()=>refreshReports().catch(e=>toast(e.message)));
$('debug-report').addEventListener('change',buttons);
$('btn-analyze').addEventListener('click',()=>{
  const name=$('debug-report').value;if(!validReport(name)){toast('请先选择有效诊断包');return;}
  task('debug-analyze '+name);
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
debugEnabled=saved('ha-debug','0')==='1';$('debug-enable').checked=debugEnabled;$('debugPanel').hidden=!debugEnabled;
applyTheme(themeFallback(),'webview');
refreshTheme();refreshFonts();refreshAll();
