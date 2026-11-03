// WebUI 静态一致性检查（不依赖浏览器）
//
// 检查内容：
//   1. index.html 引用的每个脚本/样式文件都真实存在
//   2. 实际被加载的脚本里，$('id') / getElementById('id') 引用的 id 都在 index.html 中定义
//   3. 每个脚本都能通过语法检查（由外层 node --check 做）
//
// 为什么需要它：曾发生过一次真实故障——白名单的 DOM 被删除，但真正被加载的
// app.js 仍在访问 $('f-only')，导致初始化抛错，所有页面永远停在"正在加载"。
// 这类问题浏览器控制台才会暴露，静态检查可以提前拦住。

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'webui', 'webroot');
const htmlPath = path.join(ROOT, 'index.html');

let fail = 0;
const bad = (msg) => { fail++; console.log('  FAIL ' + msg); };
const ok = (msg) => console.log('  OK   ' + msg);

if (!fs.existsSync(htmlPath)) {
  console.log('  FAIL index.html 不存在');
  process.exit(1);
}
const html = fs.readFileSync(htmlPath, 'utf8');

/* ---- 1. 引用的资源必须存在 ---- */
const scripts = [];
let missingFiles = 0;
for (const m of html.matchAll(/<script[^>]+src="([^"]+)"/g)) {
  const rel = m[1].replace(/^\.\//, '');
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) { bad('缺少脚本文件: ' + rel); missingFiles++; }
  else scripts.push(p);
}
for (const m of html.matchAll(/<link[^>]+href="([^"]+)"/g)) {
  const rel = m[1].replace(/^\.\//, '');
  if (rel.startsWith('http') || rel.startsWith('data:')) continue;
  if (!fs.existsSync(path.join(ROOT, rel))) { bad('缺少样式文件: ' + rel); missingFiles++; }
}
if (missingFiles === 0) ok('index.html 引用的资源全部存在（' + scripts.length + ' 个脚本）');

/* ---- 2. id 引用必须能解析 ---- */
const ids = new Set();
for (const m of html.matchAll(/\bid="([^"]+)"/g)) ids.add(m[1]);

const missing = new Map();
let refs = 0;
for (const file of scripts) {
  const src = fs.readFileSync(file, 'utf8');
  const name = path.relative(ROOT, file).replace(/\\/g, '/');
  for (const m of src.matchAll(/\$\('([A-Za-z0-9_-]+)'\)|getElementById\('([A-Za-z0-9_-]+)'\)/g)) {
    refs++;
    const id = m[1] || m[2];
    if (!ids.has(id)) {
      if (!missing.has(id)) missing.set(id, new Set());
      missing.get(id).add(name);
    }
  }
  // 数组形式的批量绑定，例如 const SOUND_IDS=['s-custom',...]
  const arr = src.match(/const SOUND_IDS=\[([^\]]+)\]/);
  if (arr) {
    for (const a of arr[1].matchAll(/'([^']+)'/g)) {
      refs++;
      if (!ids.has(a[1])) {
        if (!missing.has(a[1])) missing.set(a[1], new Set());
        missing.get(a[1]).add(name + ' (SOUND_IDS)');
      }
    }
  }
}

if (missing.size === 0) {
  ok('DOM 引用全部可解析（' + refs + ' 处，覆盖 ' + scripts.length + ' 个脚本）');
} else {
  for (const [id, files] of missing) {
    bad('脚本访问了不存在的 id: ' + id + '  ← ' + [...files].join(', '));
  }
  console.log('      这会让 $() 返回 null 并在初始化时抛错，表现为"页面一直正在加载"。');
}

/* ---- 3. 关键绑定不能被误删 ---- */
const mustHave = ['f-hal', 'f-audio', 'f-app', 'btn-save', 'btn-ll-reset', 'llBadge',
                  'perapp-list', 'perapp-add', 'wl-list', 'wl-add', 'llStateText',
                  'btn-debug', 'page-debug'];
const absent = mustHave.filter((x) => !ids.has(x));
if (absent.length) bad('应用页/低延迟页缺少关键元素: ' + absent.join(', '));
else ok('应用页与低延迟页关键元素齐全');

console.log('');
console.log('############ 结果 ############');
if (fail === 0) { console.log('  通过'); process.exit(0); }
console.log('  失败 ' + fail + ' 项');
process.exit(1);
