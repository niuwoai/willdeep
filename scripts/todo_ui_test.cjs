// Pure UI model regression tests; no browser or production data required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sandbox = { window: {}, Date, Array, String };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../PluginExamples/todo/ui/details.js'), 'utf8'), sandbox);
const ui = sandbox.window.TodoDetails;
test('label normalization preserves Chinese, removes duplicates and ignores invalid types', () => {
  assert.equal(JSON.stringify(ui.normalizeTags([' 界面 ', '#修复', 'BUG', 'bug', null, ''])), JSON.stringify(['界面', '修复', 'BUG']));
});
test('August 2026 calendar starts Monday and includes August 31 on Monday', () => {
  const days = ui.calendarDays(new Date(2026, 7, 31));
  assert.equal(days.length, 42); assert.equal(days[0].getDay(), 1);
  assert.equal(ui.dayKey(days[35]), '2026-08-31'); assert.equal(days[35].getDay(), 1);
});
test('date arithmetic crosses year and leap day boundaries', () => {
  assert.equal(ui.parseDay('2024-02-29').getDate(), 29);
  assert.equal(ui.parseDay('2026-02-29'), null);
  assert.equal(ui.parseDay('2026-13-01'), null);
  assert.equal(ui.calendarDays(new Date(2026, 11, 1)).length, 42);
});
test('no deadline returns a clearing payload regardless of old clock', () => {
  assert.equal(ui.dueValue({ date: '', time: '18:00', allDay: false }), '');
});
test('local time is serialized without UTC date drift', () => {
  const value = ui.dueValue({ date: '2026-08-31', time: '18:30', allDay: false });
  const date = new Date(value);
  assert.equal(ui.dayKey(date), '2026-08-31'); assert.equal(date.getHours(), 18); assert.equal(date.getMinutes(), 30);
});
test('all-day tasks expire at the end of the selected local day', () => {
  const date = new Date(ui.dueValue({ date: '2026-08-31', time: '', allDay: true }));
  assert.equal(date.getHours(), 23); assert.equal(date.getMinutes(), 59); assert.equal(date.getSeconds(), 59);
});
test('invalid dates and clocks are rejected', () => {
  assert.equal(ui.dueValue({ date: '2026-02-30', time: '18:00' }), null);
  assert.equal(ui.dueValue({ date: '2026-08-31', time: '' }), null);
  assert.equal(ui.dueValue({ date: '2026-08-31', time: '25:00' }), null);
});
test('editing clones the label list and handles undated legacy tasks', () => {
  const item = { tags: ['界面'], allDay: true };
  const draft = ui.draftFor(item); draft.tags.push('修复');
  assert.equal(item.tags.length, 1); assert.equal(draft.date, ''); assert.equal(draft.allDay, false);
});
test('Chinese and English detail dictionaries have identical keys', () => {
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../PluginExamples/todo/ui/details-i18n.js'), 'utf8'), sandbox);
  const strings = sandbox.window.TodoDetailStrings;
  assert.deepEqual(Object.keys(strings.zh).sort(), Object.keys(strings.en).sort());
});
test('labels may use object property names without silently disappearing', () => {
  assert.equal(JSON.stringify(ui.normalizeTags(['constructor', '__proto__', 'toString'])), JSON.stringify(['constructor', '__proto__', 'toString']));
});
test('release packaging includes the complete todo UI and every local asset', () => {
  const repo = path.resolve(__dirname, '..');
  const project = fs.readFileSync(path.join(repo, 'Xedit.xcodeproj/project.pbxproj'), 'utf8');
  assert.match(project, /bundle_plugin todo \.codex-plugin \.willdeep-plugin mcp\.json server ui\\n/);
  const uiRoot = path.join(repo, 'PluginExamples/todo/ui');
  for (const file of ['details.js', 'details-i18n.js', 'details.css', 'icons/LICENSE']) assert.ok(fs.existsSync(path.join(uiRoot, file)), file);
  const css = fs.readFileSync(path.join(uiRoot, 'details.css'), 'utf8');
  for (const [, file] of css.matchAll(/url\('([^']+)'\)/g)) assert.ok(fs.existsSync(path.join(uiRoot, file)), file);
});
