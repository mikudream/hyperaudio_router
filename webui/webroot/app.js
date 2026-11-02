/* 低延迟音效路由（应用版）WebUI
 *
 * 设计原则（针对此前多次"界面空白 / 数据读不到"的问题）：
 *   1. 只有一个入口 init()，各步骤独立 try/catch，任一步失败不影响其它；
 *   2. 不依赖 v3.0 的 app.js（它与自己的后端强绑定），只沿用它的视觉与类名；
 *   3. 命令执行统一走 run()，兼容 ksu.exec 的回调 / 字符串 / Promise 三种返回；
 *   4. helper 输出的两种分隔符（\x1f 与换行）都接受。
 */
(function () {
  'use strict';

  var HELPER = '/system/bin/sh /data/adb/modules/hyperaudio/webui/helper.sh';

  function $(id) { return document.getElementById(id); }

  function toast(msg, ms) {
    var t = $('toast');
    if (!t) return;
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(t._t);
    t._t = setTimeout(function () { t.hidden = true; }, ms || 2400);
  }

  /* 兼容 ksu.exec 的三种返回形式；超时或异常都 resolve 成空串，绝不 reject。 */
  function run(cmd, timeoutMs) {
    return new Promise(function (resolve) {
      var settled = false;
      function done(v) { if (!settled) { settled = true; resolve(String(v == null ? '' : v)); } }
      try {
        if (typeof ksu === 'undefined' || typeof ksu.exec !== 'function') { done(''); return; }
        var ret = ksu.exec(cmd, '{}', function (_c, out) { done(out); });
        if (typeof ret === 'string' && ret) done(ret);
        else if (ret && typeof ret.then === 'function') ret.then(function (o) { done(o); }, function () { done(''); });
      } catch (e) { done(''); }
      setTimeout(function () { done(''); }, timeoutMs || 20000);
    });
  }

  function kv(text) {
    var map = {}, lines = String(text).split(/[\u001f\n\r]+/), i, ln, p;
    for (i = 0; i < lines.length; i++) {
      ln = lines[i];
      if (!ln) continue;
      p = ln.indexOf('=');
      if (p > 0) map[ln.slice(0, p).trim()] = ln.slice(p + 1).replace(/\s+$/, '');
    }
    return map;
  }

  function setVal(id, text, state) {
    var el = $(id);
    if (!el) return;
    el.textContent = text;
    el.classList.remove('ok', 'bad');
    if (state === true) el.classList.add('ok');
    else if (state === false) el.classList.add('bad');
  }

  var S = { dolby: [], low: [] };

  function loadDolby() {
    return run(HELPER + ' dolby').then(function (out) {
      var m = kv(out);
      var apps = m['dolby_apps'];
      S.dolby = apps ? apps.split(',').filter(Boolean) : [];
      if (!S.dolby.length) {
        String(out).split(/[\u001f\n\r]+/).forEach(function (ln) {
          if (ln && ln.indexOf('=') < 0 &&
              ln !== 'dolby_apps_begin' && ln !== 'dolby_apps_end') {
            S.dolby.push(ln);
          }
        });
      }

      var payload = m['dolby_payload'] === '1';
      var comp = m['dolby_companion'] === '1';
      if (payload && comp) setVal('st-zygisk', '已注入', true);
      else if (payload) setVal('st-zygisk', '负载就绪，进程未启动', false);
      else setVal('st-zygisk', '未内置', false);

      setVal('cnt-dolby', S.dolby.length + ' 个');
      var pill = $('dolby-count');
      if (pill) pill.textContent = S.dolby.length + ' 项';
      renderList('dolby-list', S.dolby, deleteDolby);
    });
  }

  function loadStatus() {
    return run(HELPER + ' status').then(function (out) {
      var m = kv(out);

      setVal('st-daemon', m['running'] === '1' ? '运行中' : '未运行', m['running'] === '1');

      var map = {
        passed: ['已确认加载', true],
        failed: ['加载失败', false],
        timeout: ['等待超时', false],
        stale: ['记录已过期', false],
        unverified: ['未能确认', false]
      };
      var hit = map[m['audio_ready']] || ['未知', false];
      setVal('st-audio', hit[0], hit[1]);

      var inWl = false, list = [];
      String(out).split(/[\u001f\n\r]+/).forEach(function (ln) {
        if (ln === 'whitelist_begin') { inWl = true; return; }
        if (ln === 'whitelist_end') { inWl = false; return; }
        if (inWl && ln) list.push(ln);
      });
      S.low = list;
      setVal('cnt-low', list.length + ' 个');
      var pill = $('low-count');
      if (pill) pill.textContent = list.length + ' 项';
      renderList('low-list', list, deleteLow);
    });
  }

  function loadTuning() {
    return run(HELPER + ' tuning').then(function (out) {
      var parts = String(out).split('|');
      if (parts.length >= 3) {
        setVal('tuning-src', parts[1] || '未检测到');
        setVal('tuning-ver', parts[2] || '—');
      }
    });
  }

  function loadInfo() {
    return run("/system/bin/sh -c \"sed -n 's/^version=//p' /data/adb/modules/hyperaudio/module.prop\"").then(function (v) {
      setVal('info-ver', String(v).trim() || '—');
    });
  }

  function renderList(boxId, items, onDelete) {
    var box = $(boxId);
    if (!box) return;
    box.textContent = '';
    if (!items.length) {
      var e = document.createElement('div');
      e.className = 'empty';
      e.textContent = '名单为空';
      box.appendChild(e);
      return;
    }
    items.forEach(function (pkg) {
      var row = document.createElement('div');
      row.className = 'item';
      var meta = document.createElement('div');
      meta.className = 'meta';
      var p = document.createElement('div');
      p.className = 'pkg';
      p.textContent = pkg;
      meta.appendChild(p);
      var del = document.createElement('button');
      del.className = 'btn sm danger';
      del.type = 'button';
      del.textContent = '移除';
      del.addEventListener('click', function () {
        del.disabled = true;
        onDelete(pkg).then(refresh, function () { del.disabled = false; });
      });
      row.appendChild(meta);
      row.appendChild(del);
      box.appendChild(row);
    });
  }

  function errText(out) {
    var m = kv(out)['error'] || '未知错误';
    var map = {
      bad_package: '包名格式不对',
      write_failed: '写入配置失败',
      too_many_apps: '名单已满',
      dolby_not_installed: '未安装 DolbyRouter',
      dolby_offset_not_ported: '当前 DolbyRouter 未适配本机',
      no_wl_support: '后端不支持名单编辑'
    };
    return map[m] || m;
  }

  function op(cmd, okMsg) {
    return run(cmd).then(function (out) {
      if (out.indexOf('error=') >= 0) throw new Error(errText(out));
      toast(okMsg);
    });
  }

  function addDolby(pkg) { return op(HELPER + ' dolby add ' + pkg, '已添加'); }
  function deleteDolby(pkg) { return op(HELPER + ' dolby del ' + pkg, '已移除'); }
  function addLow(pkg) { return op(HELPER + ' wl add ' + pkg, '已添加'); }
  function deleteLow(pkg) { return op(HELPER + ' wl del ' + pkg, '已移除'); }

  function refresh() {
    if ($('sub')) $('sub').textContent = '正在刷新…';
    return Promise.all([loadStatus(), loadDolby(), loadTuning(), loadInfo()])
      .then(function () { if ($('sub')) $('sub').textContent = '已就绪'; })
      .catch(function () { if ($('sub')) $('sub').textContent = '部分数据读取失败'; });
  }

  function setupDock() {
    var dock = $('dock');
    if (!dock) return;
    var items = dock.querySelectorAll('.nav-item');
    function show(pageId, idx) {
      for (var i = 0; i < items.length; i++) {
        var id = items[i].getAttribute('data-page');
        var pg = $(id);
        var on = (id === pageId);
        items[i].classList.toggle('active', on);
        if (pg) pg.hidden = !on;
      }
      dock.style.setProperty('--ha-nav-index', idx);
    }
    for (var k = 0; k < items.length; k++) {
      (function (k) {
        items[k].addEventListener('click', function () {
          show(items[k].getAttribute('data-page'), k);
        });
      })(k);
    }
    show('page-status', 0);
  }

  function bindAdder(inputId, btnId, addFn) {
    var input = $(inputId), btn = $(btnId);
    if (!input || !btn) return;
    function go() {
      var v = (input.value || '').trim();
      if (!v) { toast('请输入包名'); return; }
      addFn(v).then(function () { input.value = ''; refresh(); },
        function (e) { toast('添加失败：' + (e && e.message ? e.message : e)); });
    }
    btn.addEventListener('click', go);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.keyCode === 13) { e.preventDefault(); go(); }
    });
  }

  function setupInputs() {
    bindAdder('dolby-input', 'dolby-add', addDolby);
    bindAdder('low-input', 'low-add', addLow);

    var diag = $('btn-diag');
    if (diag) {
      diag.addEventListener('click', function () {
        diag.disabled = true;
        toast('正在生成报告…', 6000);
        run(HELPER + ' diag', 120000).then(function (out) {
          var m = kv(out);
          toast(m['path'] ? '已导出到 ' + m['path'] : '导出失败', 8000);
          diag.disabled = false;
        });
      });
    }
  }

  function init() {
    try { setupDock(); } catch (e) { /* 导航失败不影响数据 */ }
    try { setupInputs(); } catch (e) { /* 同上 */ }
    refresh();
    setInterval(function () { loadStatus(); loadDolby(); }, 5000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
