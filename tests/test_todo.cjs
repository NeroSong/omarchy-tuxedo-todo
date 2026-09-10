const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const todo = vm.createContext({});
vm.runInContext(readFileSync(require('node:path').join(__dirname, '../Todo.js'), 'utf8'), todo);

test('separates metadata while preserving the complete editable line', () => {
  const raw = '  (A) 2026-09-09 Review paper +cubo @work due:2026-09-10 rec:1w custom:yes  ';
  const task = todo.parseLine(raw);
  assert.equal(task.rawText, raw);
  assert.equal(task.displayText, 'Review paper');
  assert.equal(task.priority, 'A');
  assert.equal(task.due, '2026-09-10');
  assert.equal(task.metadata.join(' '), 'due:2026-09-10 rec:1w custom:yes');
});

test('recognizes leading tags and metadata, keeps URLs and ordinary punctuation', () => {
  assert.equal(todo.parseLine('+cubo custom:yes @work Read https://example.org Note: today').displayText,
    'Read https://example.org Note: today');
  assert.equal(todo.parseLine('custom:yes +cubo @work').displayText, '');
});

test('counts each task once per tag, including object prototype names', () => {
  const tasks = ['One +cubo +cubo @work', 'Two +cubo +__proto__ @work', 'Three +constructor'].map(todo.parseLine);
  const counts = todo.counts(tasks, 'projects');
  assert.equal(counts.cubo, 2);
  assert.equal(counts.__proto__, 1);
  assert.equal(counts.constructor, 1);
  assert.equal(todo.counts(tasks, 'contexts').work, 2);
});

test('escapes task-supplied markup before rendering colored metadata', () => {
  const html = todo.metadataHtml(todo.parseLine('Title +<img> @a&b custom:<b>'), '#888888', '#aa5555');
  assert.ok(html.includes('+&lt;img&gt;'));
  assert.ok(html.includes('@a&amp;b'));
  assert.ok(html.includes('custom:&lt;b&gt;'));
  assert.ok(html.includes('<font color="#aa5555">@a&amp;b</font>'));
  assert.equal((html.match(/</g) || []).length, 4);
});

test('navigation accepts arrows, j/k and Ctrl+N/P with exact modifiers', () => {
  const qml = readFileSync(require('node:path').join(__dirname, '../Tasks.qml'), 'utf8');
  const source = qml.match(/  function navigationDelta\(event\) \{[\s\S]*?\n  \}/)[0];
  const Qt = { NoModifier: 0, ControlModifier: 1, Key_N: 78, Key_P: 80,
    Key_J: 74, Key_K: 75, Key_Down: 100, Key_Up: 101 };
  const context = vm.createContext({ Qt });
  vm.runInContext(source, context);
  for (const [key, modifiers, expected] of [
    [Qt.Key_Down, 0, 1], [Qt.Key_Up, 0, -1],
    [Qt.Key_J, 0, 1], [Qt.Key_K, 0, -1],
    [Qt.Key_N, 1, 1], [Qt.Key_P, 1, -1],
    [Qt.Key_N, 0, 0], [Qt.Key_P, 0, 0], [Qt.Key_J, 1, 0],
    [Qt.Key_N, 3, 0], [Qt.Key_Down, 2, 0]
  ]) assert.equal(context.navigationDelta({ key, modifiers }), expected);
});
