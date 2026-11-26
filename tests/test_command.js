'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname, '../webui/webroot/command.js'), 'utf8');

function load(exec, sync = false) {
  const context = { window: { ksu: { exec: (...args) => args[0] === 'echo ha_webui_probe' ? (sync ? 'ha_webui_probe\n' : undefined) : exec(...args) } }, Promise, TextDecoder, Uint8Array,
    atob, setTimeout, clearTimeout, Date };
  vm.createContext(context);
  vm.runInContext(source, context);
  return context;
}
const wrapped = text => 'rc=0|' + Buffer.from(text).toString('base64');
(async () => {
  let calls = 0;
  const sync = load(command => { calls++; assert.ok(command.endsWith("'perapp-add' 'com.example.app'")); return wrapped('ok=1'); }, true);
  const result = await sync.window.HACommand.call(['perapp-add', 'com.example.app']);
  assert.equal(result.text, 'ok=1');
  assert.equal(calls, 1);
  for (const packageName of ['com.x;id', 'com.x$(id)', "com.x'", 'com.x\nid', 'com.x abc']) {
    await assert.rejects(sync.window.HACommand.call(['perapp-add', packageName]));
  }
  assert.equal(calls, 1, 'invalid packages never reach root exec');
  await assert.rejects(sync.window.HACommand.call(['ll-save', '0', '16', '15']));
  let asyncCalls = 0;
  let asyncContext;
  asyncContext = load((command, options, callback) => {
    asyncCalls++;
    assert.equal(typeof callback, 'string');
    setTimeout(() => asyncContext.window[callback](0, wrapped('ok=1'), ''), 1);
  });
  await asyncContext.window.HACommand.call(['wl-add', 'com.example.app']);
  assert.equal(asyncCalls, 1, 'async bridge executes mutation once');
  assert.equal(Object.keys(asyncContext.window).filter(key => key.startsWith('ha_command_')).length, 0);
  let failureCalls = 0;
  const failed = load(() => { failureCalls++; throw new Error('bridge failed'); });
  await assert.rejects(failed.window.HACommand.call(['wl-add', 'com.example.app']));
  assert.equal(failureCalls, 1, 'bridge failure never replays mutation');
  const malformed = load(() => 'invalid response');
  await assert.rejects(malformed.window.HACommand.call(['wl-del', 'com.example.app']));
  const backendError = load(() => wrapped('error=publish_failed'));
  await assert.rejects(backendError.window.HACommand.call(['wl-add', 'com.example.app']));
  let running = 0;
  let maxRunning = 0;
  let queued;
  queued = load((command, options, callback) => {
    running++;
    maxRunning = Math.max(maxRunning, running);
    setTimeout(() => { running--; queued.window[callback](0, wrapped('ok=1'), ''); }, 2);
  });
  await Promise.all([queued.window.HACommand.call(['router-status']), queued.window.HACommand.call(['ll-status'])]);
  assert.equal(maxRunning, 1, 'requests are serialized');
  console.log('Command transport regression tests passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
