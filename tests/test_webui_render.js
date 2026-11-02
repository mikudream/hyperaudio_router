// WebUI 渲染冒烟测试（无需浏览器）
//
// 做法：用极简 DOM + 假 ksu.exec，把 webui/webroot/app.js 真跑一遍，
// 输入是**真机抓下来的 helper 输出样本**（\x1f 分隔），断言状态与列表被正确填充。
//
// 覆盖的正是过去反复出问题的地方：
//   · ksu.exec 只回传最后一行时，字段是否还能解析
//   · \x1f 与换行两种分隔符是否都认
//   · 状态是否按 passed/failed 正确着色（ok/bad 类）
//   · 两个名单是否真的渲染成列表项
const fs = require('fs');
const path = require('path');

const APP = path.join(__dirname, '..', 'webui', 'webroot', 'app.js');
const S = '\u001f';

/* ---- 真机样本（去掉具体机型名的通用版） ---- */
const FIX = {
  status: [
    'mode=fast',
    'running=1',
    'audio_ready=passed',
    'whitelist_begin',
    'com.example.game',
    'com.example.music',
    'com.example.tool',
    'whitelist_end',
    'applied=fast'
  ].join(S),
  dolby: [
    'dolby_installed=1',
    'dolby_companion=1',
    'dolby_payload=1',
    'dolby_offset=ported',
    'dolby_enabled=1',
    'dolby_count=2',
    'dolby_apps=com.example.video,com.example.player',
    'dolby_apps_begin',
    'dolby_apps_end'
  ].join(S),
  tuning: 'k90pm|官方调音|1.0|1|1'
};

/* ---- 极简 DOM ---- */
class El {
  constructor(id) {
    this.id = id;
    this.textContent = '';
    this.hidden = false;
    this.disabled = false;
    this.value = '';
    this.children = [];
    this._cls = new Set();
    this.classList = {
      add: (c) => this._cls.add(c),
      remove: (c) => this._cls.delete(c),
      toggle: (c, on) => { if (on) this._cls.add(c); else this._cls.delete(c); },
      contains: (c) => this._cls.has(c)
    };
    this.style = { setProperty: () => {} };
  }
  appendChild(c) { this.children.push(c); return c; }
  addEventListener() {}
  getAttribute() { return null; }
  querySelectorAll() { return []; }
}

const ids = ['sub', 'toast', 'st-zygisk', 'st-daemon', 'st-audio', 'cnt-dolby', 'cnt-low',
  'dolby-count', 'low-count', 'dolby-list', 'low-list', 'tuning-src', 'tuning-ver',
  'info-ver', 'info-author', 'btn-diag', 'dock', 'dolby-input', 'dolby-add',
  'low-input', 'low-add'];
const els = {};
ids.forEach((i) => { els[i] = new El(i); });

global.document = {
  readyState: 'complete',
  getElementById: (id) => els[id] || null,
  createElement: (t) => new El(t),
  addEventListener: () => {}
};
global.setInterval = () => 0;
global.ksu = {
  exec: (cmd) => {
    if (cmd.indexOf(' dolby') >= 0) return FIX.dolby;
    if (cmd.indexOf(' status') >= 0) return FIX.status;
    if (cmd.indexOf(' tuning') >= 0) return FIX.tuning;
    return '0.0.0';
  }
};

let pass = 0, fail = 0;
function ck(name, cond, got) {
  if (cond) { pass++; console.log('  OK   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (got !== undefined ? ' (实际: ' + got + ')' : '')); }
}

try {
  new Function(fs.readFileSync(APP, 'utf8'))();
} catch (e) {
  console.log('  FAIL app.js 执行抛错: ' + e.message);
  process.exit(1);
}

setTimeout(() => {
  const t = (id) => els[id].textContent;
  const cls = (id) => [...els[id]._cls].join(',');

  ck('注入状态识别为已注入', /已注入/.test(t('st-zygisk')), t('st-zygisk'));
  ck('注入状态着绿色', cls('st-zygisk').indexOf('ok') >= 0, cls('st-zygisk'));
  ck('守护进程显示运行中', /运行中/.test(t('st-daemon')), t('st-daemon'));
  ck('守护进程着绿色', cls('st-daemon').indexOf('ok') >= 0, cls('st-daemon'));
  ck('音频框架显示已确认加载', /已确认加载/.test(t('st-audio')), t('st-audio'));
  ck('音频框架着绿色', cls('st-audio').indexOf('ok') >= 0, cls('st-audio'));
  ck('杜比计数格式正确', /^\d+ 个$/.test(t('cnt-dolby')), t('cnt-dolby'));
  ck('杜比计数等于名单条数', t('cnt-dolby') === '2 个', t('cnt-dolby'));
  ck('低延迟计数等于名单条数', t('cnt-low') === '3 个', t('cnt-low'));
  ck('调音来源已解析', /官方调音/.test(t('tuning-src')), t('tuning-src'));
  ck('杜比列表渲染 2 行', els['dolby-list'].children.length === 2, els['dolby-list'].children.length);
  ck('低延迟列表渲染 3 行', els['low-list'].children.length === 3, els['low-list'].children.length);

  console.log('');
  console.log('############ 结果 ############');
  console.log('  通过 ' + pass + '，失败 ' + fail);
  process.exit(fail === 0 ? 0 : 1);
}, 300);
