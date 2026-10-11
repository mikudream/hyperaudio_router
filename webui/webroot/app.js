'use strict';

/* ============================================================
 * hyperaudio — KernelSU WebUI
 * ============================================================
 * 本设备环境实测要点：
 *   1) ksu.exec(cmd) 同步返回字符串
 *   2) ksu.exec 只回传 stdout 的【最后一行】，且不支持 shell 重定向
 *      → 后端 helper.sh 把所有输出用 \x1f 压成单行，前端按 \x1f 拆分
 *   3) 不能裸执行模块内的 .sh：安装时 customize.sh 的 set_perm_recursive
 *      会把文件权限统一设为 0644（无执行位），裸执行得到
 *      126 Permission denied、stdout 为空（前端会报"helper 无输出"）
 *      → 一律用 /system/bin/sh 显式解释执行，不依赖执行位
 *
 * 模式：
 *   sound 音效模式（默认）：全局走效果链，调音生效；隐藏低延迟设置
 *   fast  低延迟模式：走 fast track，延迟最低；显示低延迟设置
 * ============================================================ */

var MOD_DIR = '/data/adb/modules/hyperaudio';
var TMP_DIR = '/data/local/tmp/hyperaudio_webui';
var HELPER = MOD_DIR + '/webui/helper.sh';
var SEP = '\u001f';
/* 解释器绝对路径：不依赖 $PATH，也不依赖脚本的执行位 */
var SH = '/system/bin/sh';
var HELPER_CMD = SH + ' ' + HELPER;

/* 默认值：DOMContentLoaded 时立刻用它渲染一遍，不等后端返回 */
var DEFAULT_CONFIG = {
  enable: 'true',
  only_whitelist: 'false',
  audio_priority: '16',
  hal_priority: '20',
  app_priority: '15'
};

var S = {
  mode: 'sound',
  config: { enable: 'true', only_whitelist: 'false', audio_priority: '16', hal_priority: '20', app_priority: '15' },
  tuning: { module: '', name: '', version: '', verified: false, count: 0, loaded: false },
  whitelist: [],
  running: false,
  daemonOk: true,
  switching: false,
  /* 事务 / 开机护栏 / 挂载归属：由 helper status 的 applied / pending /
   * boot_guard / overlay 提供，用于提示"需要恢复"。 */
  applied: '',
  pending: false,
  bootGuard: 'none',
  overlay: 'none'
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

/* 把「真正耗时的工作」推迟到下一个宏任务再执行。
 *
 * 本设备上 ksu.exec(cmd) 是【同步】调用，会阻塞主线程约 500ms（要起 shell 进程）。
 * 如果在设置忙态/旋转器之后立刻调用它，设置与阻塞处在同一个宏任务里，
 * 浏览器要到任务结束才会绘制 —— 结果是忙态、旋转器、徽章全都来不及显示，
 * 界面表现为"卡一下然后直接跳到终态"。先用 setTimeout 让出一轮，
 * 忙态就有机会被绘制出来。
 * 注：这里必须用 function + var（ES5），不能用箭头函数。 */
function defer(fn) { setTimeout(fn, 0); }

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

/* 执行命令：内容为"安全字符"时直接执行，否则用 sh -c 包一层
 * 注意：不能裸执行模块内的 .sh（安装后是 0644 无执行位），
 *       调用方需自行带上 /system/bin/sh */
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
    if (k === 'daemon_ok') { S.daemonOk = (v === '1'); return; }
    if (k === 'applied') { S.applied = v; return; }
    if (k === 'pending') { S.pending = (v === '1'); return; }
    if (k === 'boot_guard') { S.bootGuard = v; return; }
    if (k === 'overlay') { S.overlay = v; return; }
    S.config[k] = v;
  });
  S.whitelist = wl;
}

/* 解析 helper tuning 命令输出：<目录名>|<显示名>|<版本>|<校验通过>|<命中模块数> */
function parseTuning(out) {
  var f = fields(out);
  var line = f[0] || '';
  var t = line.split('|');
  S.tuning = {
    module: t[0] || 'none',
    name: t[1] || '',
    version: t[2] || '',
    verified: (t[3] === '1'),
    count: parseInt(t[4], 10) || 0,
    loaded: true
  };
}

/* ---------------- 读取 ---------------- */

/* 调音来源：异步拉取，不阻塞主界面。
 * 失败不清屏、不弹错——它只是附加信息；保留"检测中…"或已有结果即可。 */
function loadTuning() {
  S.tuning.loaded = false;
  renderTuning();
  return sh(HELPER_CMD + ' tuning', 60000)
    .then(function (r) {
      if (!r.out) throw new Error('无输出');
      parseTuning(r.out);
    })
    .catch(function () {
      S.tuning = { module: 'none', name: '官方默认调音', version: '', verified: false, count: 0, loaded: true };
    })
    .then(function () {
      renderTuning();
    });
}

/* 主流程：先用默认值立即渲染，再等后端返回后覆盖。
 * 这样打开 WebUI 不再是一屏空白 + 转圈到底。
 * 注意：exec 是同步阻塞的，必须用 defer 让出一轮，否则这里的
 * "先渲染默认值 + 正在读取配置…" 也会来不及绘制（见 defer 注释）。 */
function loadAll() {
  busy(false);
  renderAll();
  $('sub').textContent = '正在读取配置…';
  return new Promise(function (resolve) {
    defer(function () {
      sh(HELPER_CMD + ' status')
        .then(function (r) {
          if (!r.out) {
            throw new Error('helper 无输出。请确认模块已完整安装，或执行：' + HELPER_CMD + ' status');
          }
          parseStatus(r.out);
          renderAll();
          resolve(true);
        })
        .catch(function (e) {
          var m = (e && e.message ? e.message : String(e));
          toast('出错: ' + m, 6000);
          $('sub').textContent = '读取失败：' + m;
          /* 失败时把界面重绘回已知状态，避免残留半截数据（见 parseStatus 的说明） */
          renderAll();
          resolve(false);
        });
    });
  });
}

/* status 到手且成功后再去拉调音来源（串行，避免与其争抢进程启动开销）。
 * status 失败就不必再白等一次阻塞了。 */
function refresh() {
  return loadAll().then(function (ok) {
    if (ok === false) return;
    return loadTuning();
  });
}

/* ---------------- 渲染 ---------------- */

var MODE_TEXT = {
  sound: '音效模式：所有应用音频都经过效果链，Dolby 调音生效（按应用档案也生效）。走普通混音线程，可能出现音频卡顿。',
  fast: '低延迟模式：应用走 fast track（FastMixer），延迟最低、不卡顿，但效果链被绕过，音效调音不生效。'
};

/* 渲染"调音来源"。
 * 检测耗时较长（要遍历全部已安装模块），因此由 loadTuning() 异步拉取后再渲染；
 * 在结果回来之前显示"检测中…"，未检测到任何第三方调音则视为官方默认调音。 */
function renderTuning() {
  var t = S.tuning || {};
  var srcEl = $('tuning-src');
  var verRow = $('tuning-ver-row');
  if (!srcEl) return;

  if (!t.loaded) { srcEl.textContent = '检测中…'; return; }

  if (!t.module || t.module === 'none') {
    srcEl.textContent = '官方默认调音';
    srcEl.title = '未检测到第三方调音模块，使用设备出厂调音';
    if (verRow) verRow.hidden = true;
    return;
  }
  srcEl.textContent = t.name || t.module;
  srcEl.title = t.module || '';
  if (verRow) {
    if (t.version) {
      verRow.hidden = false;
      $('tuning-ver').textContent = t.version + (t.verified ? '' : '（未校验生效）');
    } else {
      verRow.hidden = true;
    }
  }
  /* 多支调音模块：提示可能存在挂载覆盖，需人工确认谁在生效 */
  if (t.count > 1) {
    toast('检测到 ' + t.count + ' 支调音模块，可能互相覆盖：' + t.name, 8000);
  }
}

function renderAll() {
  var isSound = (S.mode === 'sound');
  $('tab-sound').className = 'mode-tab' + (isSound ? ' active' : '') + (S.switching ? ' busy' : '');
  $('tab-fast').className = 'mode-tab' + (!isSound ? ' active' : '') + (S.switching ? ' busy' : '');
  $('modeDesc').textContent = MODE_TEXT[S.mode];

  /* 关键：音效模式下隐藏全部低延迟相关设置 */
  $('card-fast').hidden = isSound;
  $('card-whitelist').hidden = isSound;
  $('card-sound').hidden = !isSound;

  /* 头部一键切换按钮：文案指向"切换到的目标模式" */
  var tl = $('toggleLabel');
  if (tl && !S.switching) tl.textContent = isSound ? '切换到低延迟模式' : '切换到音效模式';

  renderTuning();
  renderRecovery();

  var b = $('runBadge');
  if (S.switching) {
    b.textContent = '切换中…';
    b.className = 'hd-badge';
  } else if (isSound) {
    b.textContent = '音效模式';
    b.className = 'hd-badge on';
  } else if (!S.daemonOk) {
    b.textContent = '低延迟 · 守护进程缺失';
    b.className = 'hd-badge off';
  } else {
    b.textContent = S.running ? '低延迟 · 守护进程运行中' : '低延迟 · 守护进程未运行';
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

/* 恢复提示。
 *
 * 触发条件（任一）：
 *   · pending=1      —— 上次切换没走完（可能中途被杀/重启），事务未收尾
 *   · bootGuard≠none —— 开机护栏已生效：上次应用失败，本次已强制回到原始配置
 *   · overlay=conflict —— 我们叠加的那层被别的模块替换了，本模块拒绝强行动手
 *
 * 这几种情况都不会自动重试（避免反复失败），所以必须让用户看得见、能主动恢复。 */
function renderRecovery() {
  var card = $('card-recover');
  if (!card) return;
  var why = [];
  if (S.pending) why.push('上次模式切换没有正常结束');
  if (S.bootGuard && S.bootGuard !== 'none') {
    why.push('上次应用失败，已临时回到系统原始配置（原因：' + S.bootGuard + '）');
  }
  if (S.overlay === 'conflict') {
    why.push('本模块叠加的音频配置层已被其他模块改动，本模块不会强行覆盖');
  }
  if (!why.length) { card.hidden = true; return; }
  card.hidden = false;
  $('recoverWhy').textContent = why.join('；') +
    '。点下方按钮可撤销本模块的全部改动，回到系统原始配置（不重启即可生效）。';
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

/* 切换过程中：按钮/标签页显示旋转器并禁用，界面本身保持可见可读。
 * 不用全屏遮罩——切换要等 audioserver 重启，遮屏反而让人以为卡死。 */
function setSwitching(on, name) {
  var label = (name === 'fast' ? '低延迟模式' : '音效模式');
  var el = $('toggleSpin');
  if (el) el.hidden = !on;
  var tl = $('toggleLabel');
  if (tl) tl.textContent = on ? ('切换到' + label + '…') : ('切换到' + label);
  var tb = $('btn-toggle');
  if (tb) tb.disabled = !!on;
  ['tab-sound', 'tab-fast'].forEach(function (id) {
    var t = $(id);
    if (t) {
      t.disabled = !!on;
      t.className = 'mode-tab' + (t.dataset.mode === S.mode ? ' active' : '') + (on ? ' busy' : '');
    }
  });
  var m = $('modeMsg');
  if (m && on) {
    m.innerHTML = '<span class="spin-xs"></span><span>正在切换到' + label + '，音频服务重启中…</span>';
    m.hidden = false;
  }
}

/* runtime.sh 的错误名 → 给用户看的话。
 * 不做映射时会直接把 error=xxx 的原始代号弹给用户，看不懂。 */
var APPLY_ERR = {
  no_tuning_config: '未找到提供音频端口配置的调音模块（音效模式需要它）',
  cannot_derive_target: '无法从调音模块路径推导出系统上的生效路径',
  target_missing: '系统上的音频端口配置文件不存在',
  snapshot_failed: '无法保存端口配置基线',
  port_patch_empty: '端口补丁产生了空文件，已放弃',
  no_port_changes: '端口标志本来就是目标状态，无需补丁（可能已被其他模块改过）',
  bind_mount_denied: '无法把补丁叠加到系统路径（挂载被拒绝）',
  mount_not_visible: '挂载已建立但对系统不可见',
  unmount_failed_reboot_required: '撤销上一层的挂载失败，需要重启',
  overlay_changed_by_another_module: '该路径已被其他模块改动，本模块不会强行覆盖',
  apply_failed_restored_native: '应用失败，已恢复为系统原始配置',
  rollback_incomplete_reboot_required: '应用失败且回滚未完成，需要重启',
  legacy_source_repair_failed: '调音模块的端口文件曾被旧版本改动，修复失败',
  mode_switch_missing: '模块文件不完整（找不到模式状态机），请重新刷入',
  daemon_start_failed: '守护进程启动失败',
  cannot_save_mode: '无法写入模式文件',
  bad_mode: '内部错误：模式参数不合法'
};

function applyErrText(raw) {
  var out = String(raw == null ? '' : raw);
  /* helper 回的是单行 \x1f 分隔；取出 error= 的值 */
  var f = fields(out), code = '';
  for (var i = 0; i < f.length; i++) {
    var ln = String(f[i]).replace(/[\r\n]+$/, '');
    if (ln.indexOf('error=') === 0) { code = ln.slice(6); break; }
  }
  if (!code) return out || '无输出';
  /* 端口补丁被拒时会带上具体子原因 */
  if (code.indexOf('port_patch_rejected') === 0) {
    var sub = code.slice('port_patch_rejected'.length).replace(/^_/, '');
    return '端口配置无法安全改写' + (sub ? '（' + sub + '）' : '') + '，未做任何改动';
  }
  if (APPLY_ERR[code]) return APPLY_ERR[code];
  return code;
}

function switchMode(mode) {
  if (S.switching) return;
  if (mode === S.mode) { toast('已经是该模式'); return; }
  var name = (mode === 'sound' ? '音效模式' : '低延迟模式');
  S.switching = true;
  setSwitching(true, mode);
  /* 让出一轮宏任务，先把这个忙态画出来，再发起会阻塞的 exec */
  defer(function () {
    sh(HELPER_CMD + ' setmode ' + mode, 40000)
      .then(function (r) {
        var f = fields(r.out);
        if (f.indexOf('ok=1') < 0) throw new Error(applyErrText(r.out));
        S.mode = mode;
        return loadAll();
      })
      .then(function () {
        S.switching = false;
        setSwitching(false, mode);
        $('modeMsg').innerHTML = '';
        $('modeMsg').textContent = '已切换到' + name +
          '（音频服务仅在端口标志变化时才会重启；请强行停止并重新打开游戏）';
        $('modeMsg').hidden = false;
        toast('已切换到' + name, 2600);
        /* 模式变了，低延迟相关显示项需要重绘 */
        renderAll();
      })
      .catch(function (e) {
        S.switching = false;
        setSwitching(false, (S.mode === 'sound' ? 'fast' : 'sound'));
        $('modeMsg').hidden = true;
        toast('切换失败: ' + (e && e.message ? e.message : e), 6000);
        renderAll();
      });
  });
}

/* 恢复到系统原始配置：撤销本模块的全部改动（端口层、事务、开机护栏）。
 * 不会自动重试失败的应用，所以给用户一个显式的脱困入口。 */
function doRecover() {
  if (S.switching) return;
  S.switching = true;
  busy(true);
  defer(function () {
    sh(HELPER_CMD + ' recover', 30000)
      .then(function (r) {
        var f = fields(r.out);
        if (f.indexOf('ok=1') < 0) throw new Error(applyErrText(r.out));
        return loadAll();
      })
      .then(function () {
        S.switching = false;
        busy(false);
        toast('已恢复到系统原始配置', 3000);
        renderAll();
      })
      .catch(function (e) {
        S.switching = false;
        busy(false);
        toast('恢复失败: ' + (e && e.message ? e.message : e), 6000);
        renderAll();
      });
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
    ' && ' + HELPER_CMD + ' save ' + TMP_DIR + '/in.json';
  /* 先让遮罩画出来，再发起阻塞的 exec（见 defer 注释） */
  defer(function () {
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
  $('btn-reload').addEventListener('click', function () { refresh(); });
  var brc = $('btn-recover');
  if (brc) brc.addEventListener('click', function () { doRecover(); });
  $('btn-save').addEventListener('click', function () { save(); });
  /* 头部一键切换：在当前模式的反方向之间切换 */
  $('btn-toggle').addEventListener('click', function () {
    switchMode(S.mode === 'sound' ? 'fast' : 'sound');
  });
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
  refresh();
});
