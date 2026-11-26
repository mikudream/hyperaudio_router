/* router-ui.js —— 两个名单的页面（音效 / 低延迟）
 *
 * 独立实现，不依赖 app.js：
 *   · 导航由 ui.js 统一管理（本文件只负责页面内容）
 *   · 通过 bin/webui.sh 的 rc=N|base64 契约取数据、做增删
 *   · 名单互斥由 router.sh 保证：加入一边会自动从另一边移出，并回显 moved_from=
 */
(function () {
  'use strict';


  function $(id) { return document.getElementById(id); }

  function toast(msg, ms) {
    var t = $('toast');
    if (!t) { t = document.createElement('div'); t.id = 'toast'; t.className = 'toast'; document.body.appendChild(t); }
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(t._t);
    t._t = setTimeout(function () { t.hidden = true; }, ms || 2400);
  }

  function call(args) { return window.HACommand.call(args); }

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
    if (!items.length) return;   // 空名单不显示“名单为空”占位
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

  var pendingRefresh = null;
  function refresh() {
    if (pendingRefresh) return pendingRefresh;
    pendingRefresh = call(['router-status']).then(function (r) {
      var m = parseKV(r.text);
      var ok = r.rc === 0 && m['ok'] === '1';
      var st = $('perapp-state');
      if (!ok) {
        if (st) { st.textContent = '状态未知'; st.className = 'value'; }
        return;
      }
      state.perapp = listOf(m['perapp_apps']);
      state.wl = listOf(m['wl_apps']);

      setCount('soundCount', state.perapp.length);
      setCount('wl-count', state.wl.length);

      if (st) {
        var payload = m['perapp_payload'] === '1';
        var publish = m['config_publish'];
        var ready = payload && publish === 'ok';
        st.textContent = !payload ? '缺少负载文件' : ready ? '负载就绪' :
          !publish || publish === 'unknown' ? '名单同步未确认' : '名单同步异常';
        st.className = 'value ' + (ready ? 'ok' : 'bad');
      }

      renderBox('perapp-list', state.perapp, function (p) {
        return call(['perapp-del', p]).then(function (x) {
          if (x.rc !== 0 || parseKV(x.text).ok !== '1') throw new Error('删除失败');
          toast('已移除，重启目标应用后更新音频链路');
        });
      });
      renderBox('wl-list', state.wl, function (p) {
        return call(['wl-del', p]).then(function (x) {
          if (x.rc !== 0 || parseKV(x.text).ok !== '1') throw new Error('删除失败');
          toast('已移除，重启目标应用后更新音频链路');
        });
      });
    }).catch(function () {
      var status = $('perapp-state');
      if (status) { status.textContent = '状态未知'; status.className = 'value'; }
    }).finally(function () { pendingRefresh = null; });
    return pendingRefresh;
  }

  function bindAdder(inputId, btnId, action) {
    var input = $(inputId), btn = $(btnId);
    if (!input || !btn) return;
    function go() {
      var v = (input.value || '').trim();
      if (btn.disabled) return;
      if (!window.HACommand.validPackage(v)) { toast('包名格式不正确'); return; }
      btn.disabled = true;
      call([action, v]).then(function (x) {
        btn.disabled = false;
        var kv = parseKV(x.text);
        // 必须真的拿到 ok=1 才算成功；空响应（超时）不能清空输入、不能报“已添加”。
        if (x.rc !== 0 || kv['ok'] !== '1' || kv['error']) {
          toast('添加失败：' + (kv['error'] || (x.rc !== 0 ? ('rc=' + x.rc) : '无响应')));
          return;
        }
        input.value = '';
        var hint = movedHint(kv);
        toast((hint ? ('已添加，' + hint) : '已添加') + '，重启目标应用后生效');
        refresh();
      }).catch(function (error) {
        btn.disabled = false;
        toast('添加失败：' + error.message);
      });
    }
    btn.addEventListener('click', go);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.keyCode === 13) { e.preventDefault(); go(); }
    });
  }

  function init() {
    try {
      bindAdder('perapp-input', 'perapp-add', 'perapp-add');
      bindAdder('wl-input', 'wl-add', 'wl-add');
    } catch (e) { }
    refresh();
    setInterval(function () { if (!document.hidden) refresh(); }, 5000);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) refresh(); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
