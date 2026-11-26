/* Shared KernelSU WebUI command transport. Each request is executed once. */
(function () {
  'use strict';

  var sequence = 0;
  var queue = Promise.resolve();
  var useSync;
  var helper = '/system/bin/sh /data/adb/modules/hyperaudio/bin/webui.sh';
  var actions = {
    'router-status': 0, 'status': 0, 'll-status': 0, 'tuning': 0,
    'theme': 0, 'fonts': 0, 'boot-status': 0, 'start-backends': 0,
    'perapp-add': 1, 'perapp-del': 1, 'wl-add': 1, 'wl-del': 1,
    'll-save': 3
  };

  function validPackage(value) {
    return typeof value === 'string' && value.length <= 120 &&
      /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+(?![\s\S])/.test(value);
  }

  function quote(value) {
    return "'" + value.replace(/'/g, "'\\''") + "'";
  }

  function command(args) {
    if (!Array.isArray(args) || typeof args[0] !== 'string' ||
        !Object.prototype.hasOwnProperty.call(actions, args[0]) || args.length !== actions[args[0]] + 1) {
      throw new Error('操作参数不正确');
    }
    var values = args.map(String);
    if (/^(perapp|wl)-(add|del)$/.test(values[0]) && !validPackage(values[1])) {
      throw new Error('包名格式不正确');
    }
    if (values[0] === 'll-save' && values.slice(1).some(function (value) {
      return !/^([1-9]|[1-9][0-9])$/.test(value);
    })) {
      throw new Error('优先级必须是 1–99 的整数');
    }
    return helper + ' ' + values.map(quote).join(' ');
  }

  function decode(raw) {
    var line = String(raw || '').trim().split(/\r?\n/).pop();
    var match = /^rc=(\d+)\|([A-Za-z0-9+/=]*)$/.exec(line);
    if (!match) throw new Error('未收到有效的操作结果');
    var binary = atob(match[2]);
    var bytes = Uint8Array.from(binary, function (character) { return character.charCodeAt(0); });
    var text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    var result = { rc: Number(match[1]), text: text };
    if (result.rc !== 0) throw new Error(text || '命令执行失败');
    if (/(^|\n)error=/.test(text)) throw new Error(text.trim());
    return result;
  }

  function execute(cmd) {
    return new Promise(function (resolve, reject) {
      if (!window.ksu || typeof window.ksu.exec !== 'function') {
        reject(new Error('请在支持 KernelSU WebUI 接口的管理器中打开'));
        return;
      }
      var name = 'ha_command_' + Date.now() + '_' + (++sequence);
      var settled = false;
      var timer = setTimeout(function () {
        finish(new Error('等待返回超时，请重新读取状态确认结果'));
      }, 30000);

      function finish(error, output) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        delete window[name];
        if (error) reject(error);
        else resolve(output);
      }

      window[name] = function (code, stdout, stderr) {
        if (Number(code) !== 0) finish(new Error(String(stderr || stdout || '执行失败')));
        else finish(null, String(stdout || ''));
      };
      try {
        // Probe only a harmless command to choose the bridge overload. Never
        // replay a mutation if that overload later fails or times out.
        if (useSync === undefined) {
          useSync = false;
          try {
            var probe = window.ksu.exec('echo ha_webui_probe');
            useSync = typeof probe === 'string' && probe.trim() === 'ha_webui_probe';
          } catch (_) {}
        }
        var returned = useSync ? window.ksu.exec(cmd) : window.ksu.exec(cmd, '{}', name);
        if (typeof returned === 'string' && returned) finish(null, returned);
        else if (returned && typeof returned.then === 'function') {
          returned.then(function (value) {
            finish(null, typeof value === 'string' ? value : String(value.stdout || ''));
          }, function (error) { finish(error); });
        }
      } catch (error) { finish(error); }
    });
  }

  function call(args) {
    var cmd;
    try { cmd = command(args); }
    catch (error) { return Promise.reject(error); }
    var request = queue.then(function () { return execute(cmd); }).then(decode);
    queue = request.catch(function () {});
    return request;
  }

  window.HACommand = { call: call, validPackage: validPackage };
})();
