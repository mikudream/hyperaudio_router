'use strict';

/* ============================================================
 * hyperaudio — KernelSU WebUI
 * ============================================================
 * 本设备环境实测要点：
 *   1) ksu.exec(cmd) 同步返回字符串
 *   2) ksu.exec 只回传 stdout 的【最后一行】，且不支持 shell 重定向
 *      → 后端 helper.sh 把所有输出用 \x1f 压成单行，前端按 \x1f 拆分
 *
 * 模式：
 *   sound 音效模式（默认）：全局走效果链，调音生效；隐藏低延迟设置
 *   fast  低延迟模式：走 fast track，延迟最低；显示低延迟设置
 * ============================================================ */

var MOD_DIR = '/data/adb/modules/hyperaudio';
var TMP_DIR = '/data/local/tmp/hyperaudio_webui';
var HELPER = MOD_DIR + '/webui/helper.sh';
var SEP = '\u001f';

var S = {
  mode: 'sound',
  config: { enable: 'true', only_whitelist: 'false', audio_priority: '16', hal_priority: '20', app_priority: '15' },
  tuning: { module: '', name: '', version: '', verified: false },
  whitelist: [],
  running: false
};

/* ---------------- 基础工具 ---------------- */

function $(id) { return document.getElementById(id); }

function toast(msg, ms) {
  var t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(function () { t.hidden = true; }, ms || 2200);
}

function busy(on) { $('mask').hidden = !on; }

function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

var __execSeq = 0;
function exec(cmd, timeoutMs) {
  timeoutMs = timeoutMs || 30000;
  if (typeof ksu === 'undefined' || typeof ksu.exec !== 'function') {
    return Promise.reject(new Error('未检测到 KernelSU WebUI 接口'));
  }
  var ret;
  try {
    ret = ksu.exec(cmd);
  } catch (e) {
    return Promise.reject(new Error('ksu.exec 抛异常: ' + (e && e.message ? e.message : e)));
  }
  if (typeof ret === 'string' || ret == null) {
    return Promise.resolve({ out: (ret == null ? '' : String(ret)) });
  }
  if (ret && typeof ret.then === 'function') {
    return ret.then(function (v) {
      if (v && typeof v === 'object') return { out: String(v.stdout != null ? v.stdout : '') };
      return { out: v == null ? '' : String(v) };
    });
  }
  return new Promise(function (resolve, reject) {
    var done = false;
    var cbId = 'exec_callback_' + Date.now() + '_' + (__execSeq++);
    var timer = setTimeout(function () {
      if (done) return;
      done = true;
      try { delete window[cbId]; } catch (e) { window[cbId] = undefined; }
      reject(new Error('执行超时（' + timeoutMs + 'ms）'));
    }, timeoutMs);
    window[cbId] = function (errno, stdout) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { delete window[cbId]; } catch (e) { window[cbId] = undefined; }
      resolve({ out: stdout == null ? '' : String(stdout) });
    };
    try {
      ksu.exec(cmd, JSON.stringify({}), cbId);
    } catch (e) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      reject(new Error('ksu.exec 调用失败: ' + (e && e.message ? e.message : e)));
    }
  });
}

/* 直接调用脚本（helper 输出单行、无特殊字符）；需管道时用 sh -c "..." */
function sh(cmd, timeoutMs) {
  if (/^[A-Za-z0-9_\/.:%=\- ]+$/.test(cmd)) return exec(cmd, timeoutMs);
  return exec('sh -c "' + String(cmd).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"', timeoutMs);
}

function fields(out) {
  var arr = String(out == null ? '' : out).split(SEP);
  while (arr.length && arr[arr.length - 1] === '') arr.pop();
  return arr;
}

/* ---------------- 解析 ---------------- */

function parseStatus(out) {
  var f = fields(out), wl = [], inWl = false;
  f.forEach(function (ln) {
    ln = String(ln).replace(/[\r\n]+$/, '');
    if (ln === '') return;
    if (ln === 'whitelist_begin') { inWl = true; return; }
    if (ln === 'whitelist_end') { inWl = false; return; }
    if (inWl) { wl.push(ln); return; }
    var i = ln.indexOf('=');
    if (i < 0) return;
    var k = ln.slice(0, i), v = ln.slice(i + 1);
    if (k === 'error') throw new Error('配置读取失败: ' + v);
    if (k === 'mode') { S.mode = (v === 'fast' ? 'fast' : 'sound'); return; }
    if (k === 'running') { S.running = (v === '1'); return; }
    /* 调音来源：<目录名>|<显示名>|<版本>|<校验通过> */
    if (k === 'tuning') {
      var t = v.split('|');
      S.tuning = {
        module: t[0] || '',
        name: t[1] || '',
        version: t[2] || '',
        verified: (t[3] === '1')
      };
      return;
    }
    S.config[k] = v;
  });
  S.whitelist = wl;
}

/* ---------------- 读取 ---------------- */

function loadAll() {
  busy(true);
  $('sub').textContent = '正在读取配置…';
  return sh(HELPER + ' status')
    .then(function (r) {
      if (!r.out) throw new Error('helper 无输出');
      parseStatus(r.out);
      renderAll();
      busy(false);
    })
    .catch(function (e) {
      busy(false);
      var m = (e && e.message ? e.message : String(e));
      toast('出错: ' + m, 6000);
      $('sub').textContent = '读取失败：' + m;
    });
}

/* ---------------- 渲染 ---------------- */

var MODE_TEXT = {
  sound: '音效模式：所有应用音频都经过效果链，Dolby 调音生效（按应用档案也生效）。走普通混音线程，可能出现音频卡顿。',
  fast: '低延迟模式：应用走 fast track（FastMixer），延迟最低、不卡顿，但效果链被绕过，音效调音不生效。'
};

/* 渲染"调音来源"（扫描本机已安装模块后检测得到） */
function renderTuning() {
  var t = S.tuning || {};
  var srcEl = $('tuning-src');
  var verRow = $('tuning-ver-row');
  if (!srcEl) return;

  if (!t.module || t.module === 'none') {
    srcEl.textContent = '未检测到调音模块';
    if (verRow) verRow.hidden = true;
    return;
  }
  srcEl.textContent = t.name || t.module;
  if (verRow) {
    if (t.version) {
      verRow.hidden = false;
      $('tuning-ver').textContent = t.version + (t.verified ? '' : '（未校验生效）');
    } else {
      verRow.hidden = true;
    }
  }
}

function renderAll() {
  var isSound = (S.mode === 'sound');
  $('tab-sound').className = 'mode-tab' + (isSound ? ' active' : '');
  $('tab-fast').className = 'mode-tab' + (!isSound ? ' active' : '');
  $('modeDesc').textContent = MODE_TEXT[S.mode];

  /* 关键：音效模式下隐藏全部低延迟相关设置 */
  $('card-fast').hidden = isSound;
  $('card-whitelist').hidden = isSound;
  $('card-sound').hidden = !isSound;

  renderTuning();

  var b = $('runBadge');
  if (isSound) {
    b.textContent = '音效模式';
    b.className = 'hd-badge on';
  } else {
    b.textContent = S.running ? '守护进程运行中' : '守护进程未运行';
    b.className = 'hd-badge ' + (S.running ? 'on' : 'off');
  }

  $('sub').textContent = (isSound ? '音效模式' : '低延迟模式') +
    ' · 白名单 ' + S.whitelist.length + ' 项';

  $('f-enable').checked = (S.config.enable === 'true');
  $('f-only').checked = (S.config.only_whitelist === 'true');
  $('f-hal').value = S.config.hal_priority;
  $('f-audio').value = S.config.audio_priority;
  $('f-app').value = S.config.app_priority;

  renderWhitelist();
}

function renderWhitelist() {
  var box = $('wl-list');
  box.innerHTML = '';
  $('wl-count').textContent = S.whitelist.length + ' 项';

  if (!S.whitelist.length) {
    var e = document.createElement('div');
    e.className = 'empty';
    e.textContent = '白名单为空，请在上方输入包名添加';
    box.appendChild(e);
    return;
  }

  S.whitelist.forEach(function (pkg) {
    var el = document.createElement('div');
    el.className = 'item';

    var meta = document.createElement('div');
    meta.className = 'meta';
    var p1 = document.createElement('div');
    p1.className = 'pkg';
    p1.textContent = pkg;
    meta.appendChild(p1);

    var del = document.createElement('button');
    del.className = 'btn sm danger';
    del.textContent = '移除';
    del.addEventListener('click', function () {
      var i = S.whitelist.indexOf(pkg);
      if (i >= 0) S.whitelist.splice(i, 1);
      renderWhitelist();
      $('sub').textContent = (S.mode === 'sound' ? '音效模式' : '低延迟模式') + ' · 白名单 ' + S.whitelist.length + ' 项';
    });

    el.appendChild(meta);
    el.appendChild(del);
    box.appendChild(el);
  });
}

/* ---------------- 模式切换 ---------------- */

function switchMode(mode) {
  if (mode === S.mode) { toast('已经是该模式'); return; }
  var name = (mode === 'sound' ? '音效模式' : '低延迟模式');
  busy(true);
  $('modeMsg').hidden = true;
  sh(HELPER + ' setmode ' + mode, 40000)
    .then(function (r) {
      var f = fields(r.out);
      if (f.indexOf('ok=1') >= 0) {
        S.mode = mode;
        $('modeMsg').textContent = '已切换到' + name + '（音频服务已重启）';
        $('modeMsg').hidden = false;
        toast('已切换到' + name, 2600);
        return loadAll();
      }
      busy(false);
      toast('切换失败: ' + (r.out || '无输出'), 5000);
    })
    .catch(function (e) {
      busy(false);
      toast('切换出错: ' + (e && e.message ? e.message : e), 5000);
    });
}

/* ---------------- 保存（低延迟模式参数）---------------- */

function collect() {
  return {
    enable: $('f-enable').checked ? 'true' : 'false',
    only_whitelist: $('f-only').checked ? 'true' : 'false',
    audio_priority: String(parseInt($('f-audio').value, 10) || 16),
    hal_priority: String(parseInt($('f-hal').value, 10) || 20),
    app_priority: String(parseInt($('f-app').value, 10) || 15),
    whitelist: S.whitelist.slice()
  };
}

function save() {
  var b64;
  try {
    b64 = btoa(unescape(encodeURIComponent(JSON.stringify(collect()))));
  } catch (e) { toast('数据编码失败'); return; }

  busy(true);
  var cmd = 'mkdir -p ' + TMP_DIR +
    ' && printf "%s" ' + q(b64) + ' | base64 -d > ' + TMP_DIR + '/in.json' +
    ' && sh ' + HELPER + ' save ' + TMP_DIR + '/in.json';
  sh(cmd, 30000)
    .then(function (r) {
      var f = fields(r.out);
      busy(false);
      if (f.indexOf('ok=1') >= 0) {
        toast('已保存', 2400);
        return loadAll();
      }
      toast('保存失败: ' + (r.out || '无输出'), 5000);
    })
    .catch(function (e) {
      busy(false);
      toast('保存出错: ' + (e && e.message ? e.message : e), 5000);
    });
}

/* ---------------- 事件 ---------------- */

function addPkg() {
  var v = $('f-newpkg').value.trim().replace(/\s+/g, '');
  if (!v) { toast('请输入包名'); return; }
  if (!/^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$/.test(v)) { toast('包名格式不正确（示例 com.xxx.game）'); return; }
  if (S.whitelist.indexOf(v) >= 0) { toast('该包名已在白名单中'); return; }
  S.whitelist.push(v);
  S.whitelist.sort();
  $('f-newpkg').value = '';
  renderWhitelist();
  toast('已加入：' + v);
}

function bind() {
  $('tab-sound').addEventListener('click', function () { switchMode('sound'); });
  $('tab-fast').addEventListener('click', function () { switchMode('fast'); });
  $('btn-add').addEventListener('click', addPkg);
  $('f-newpkg').addEventListener('keydown', function (e) {
    if (e.key === 'Enter' || e.keyCode === 13) { e.preventDefault(); addPkg(); }
  });
  $('btn-reload').addEventListener('click', function () { loadAll(); });
  $('btn-save').addEventListener('click', function () { save(); });
}

/* ---------------- 启动 ---------------- */

document.addEventListener('DOMContentLoaded', function () {
  busy(false);
  if (typeof ksu === 'undefined') {
    $('sub').textContent = '未检测到 KernelSU WebUI 接口（请在 KernelSU / APatch 管理器中打开本模块的 WebUI）';
    ['btn-save', 'btn-reload', 'btn-add'].forEach(function (id) {
      var el = $(id); if (el) el.disabled = true;
    });
    return;
  }
  bind();
  loadAll();
});
