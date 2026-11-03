/* router-ui.js —— 两个名单的页面（音效 / 低延迟）
 *
 * 独立实现，不依赖 app.js：
 *   · 导航由 ui.js 统一管理（本文件只负责页面内容）
 *   · 通过 bin/webui.sh 的 rc=N|base64 契约取数据、做增删
 *   · 名单互斥由 router.sh 保证：加入一边会自动从另一边移出，并回显 moved_from=
 */
(function () {
  'use strict';

  var WEBUI = '/system/bin/sh /data/adb/modules/hyperaudio/bin/webui.sh';

  function $(id) { return document.getElementById(id); }

  function toast(msg, ms) {
    var t = $('toast');
    if (!t) { t = document.createElement('div'); t.id = 'toast'; t.className = 'toast'; document.body.appendChild(t); }
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(t._t);
    t._t = setTimeout(function () { t.hidden = true; }, ms || 2400);
  }

  /* 解码 rc=N|BASE64 */
  function decode(raw) {
    var s = String(raw || '').trim();
    var m = /^rc=(-?\d+)\|([A-Za-z0-9+/=]*)$/.exec(s);
    if (!m) {
      // 兼容：没有包裹时直接当作文本
      return { rc: 0, text: s };
    }
    var text = '';
    try {
      var bin = atob(m[2]);
      var bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      text = new TextDecoder('utf-8').decode(bytes);
    } catch (e) { text = ''; }
    return { rc: parseInt(m[1], 10), text: text };
  }

  function call(args) {
    return new Promise(function (resolve) {
      var settled = false;
      function done(v) { if (!settled) { settled = true; resolve(decode(v)); } }
      try {
        if (typeof ksu === 'undefined' || typeof ksu.exec !== 'function') { done(''); return; }
        var ret = ksu.exec(WEBUI + ' ' + args, '{}', function (_c, out) { done(out); });
        if (typeof ret === 'string' && ret) done(ret);
        else if (ret && typeof ret.then === 'function') ret.then(function (o) { done(o); }, function () { done(''); });
      } catch (e) { done(''); }
      setTimeout(function () { done(''); }, 30000);
    });
  }

  function parseKV(text) {
    var map = {};
    String(text).split(/[\u001f\n\r]+/).forEach(function (ln) {
      var i = ln.indexOf('=');
      if (i > 0) map[ln.slice(0, i).trim()] = ln.slice(i + 1).replace(/\s+$/, '');
    });
    return map;
  }

  function listOf(csv) { return csv ? csv.split(',').filter(Boolean) : []; }

  /* ---------- 渲染 ---------- */

  function renderBox(boxId, items, onDel) {
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
      row.className = 'row';
      var copy = document.createElement('span');
      copy.className = 'copy';
      var b = document.createElement('b');
      b.textContent = pkg;
      copy.appendChild(b);
      var btn = document.createElement('button');
      btn.className = 'btn secondary';
      btn.type = 'button';
      btn.textContent = '移除';
      btn.addEventListener('click', function () {
        btn.disabled = true;
        onDel(pkg).then(refresh, function (e) {
          btn.disabled = false;
          toast('操作失败：' + (e && e.message ? e.message : e));
        });
      });
      row.appendChild(copy);
      row.appendChild(btn);
      box.appendChild(row);
    });
  }

  function setCount(id, n) { var el = $(id); if (el) el.textContent = n + ' 项'; }

  var state = { perapp: [], wl: [] };

  function movedHint(kv) {
    if (kv['moved_from'] === 'lowlat') return '已从低延迟名单移出';
    if (kv['moved_from'] === 'sound') return '已从音效名单移出';
    return '';
  }

  function refresh() {
    return call('router-status').then(function (r) {
      var m = parseKV(r.text);
      state.perapp = listOf(m['perapp_apps']);
      state.wl = listOf(m['wl_apps']);

      setCount('soundCount', state.perapp.length);
      setCount('wl-count', state.wl.length);

      var toggle = $('perapp-enable');
      if (toggle) toggle.checked = m['perapp_enabled'] === '1';

      var st = $('perapp-state');
      if (st) {
        var payload = m['perapp_payload'] === '1';
        var comp = m['perapp_companion'] === '1';
        st.textContent = (payload && comp) ? '已注入' : (payload ? '负载就绪，进程未启动' : '未内置');
        st.className = (payload && comp) ? 'ok' : 'bad';
      }

      renderBox('perapp-list', state.perapp, function (p) {
        return call('perapp-del ' + p).then(function (x) {
          if (x.rc !== 0 || /error=/.test(x.text)) throw new Error('删除失败');
          toast('已移除');
        });
      });
      renderBox('wl-list', state.wl, function (p) {
        return call('wl-del ' + p).then(function (x) {
          if (x.rc !== 0 || /error=/.test(x.text)) throw new Error('删除失败');
          toast('已移除');
        });
      });
    });
  }

  function bindAdder(inputId, btnId, action) {
    var input = $(inputId), btn = $(btnId);
    if (!input || !btn) return;
    function go() {
      var v = (input.value || '').trim();
      if (!v) { toast('请输入包名'); return; }
      btn.disabled = true;
      call(action + ' ' + v).then(function (x) {
        btn.disabled = false;
        if (/error=/.test(x.text)) {
          var code = (parseKV(x.text)['error'] || '');
          toast(code === 'bad_package' ? '包名格式不对' : ('添加失败：' + code));
          return;
        }
        input.value = '';
        var hint = movedHint(parseKV(x.text));
        toast(hint ? ('已添加，' + hint) : '已添加');
        refresh();
      });
    }
    btn.addEventListener('click', go);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.keyCode === 13) { e.preventDefault(); go(); }
    });
  }

  function bindToggle() {
    var toggle = $('perapp-enable');
    if (!toggle) return;
    toggle.addEventListener('change', function () {
      var want = toggle.checked ? '1' : '0';
      toggle.disabled = true;
      call('perapp-enable ' + want).then(function (x) {
        toggle.disabled = false;
        if (x.rc !== 0 || /error=/.test(x.text)) {
          toggle.checked = !toggle.checked;
          toast('切换失败，请稍后重试');
          return;
        }
        toast(toggle.checked ? '音效链路已开启' : '音效链路已关闭，所有应用保持系统默认');
      });
    });
  }

  function init() {
    try {
      bindAdder('perapp-input', 'perapp-add', 'perapp-add');
      bindAdder('wl-input', 'wl-add', 'wl-add');
      bindToggle();
    } catch (e) { }
    refresh();
    setInterval(refresh, 5000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
