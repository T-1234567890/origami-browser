const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const vm = require('node:vm');
const root = resolve(__dirname, '..');
const source = readFileSync(resolve(root, 'download.js'), 'utf8');
const version = '1.0.0-beta.1';
const valid = {version, channel: 'beta', downloadURL: `https://github.com/T-1234567890/origami-browser/releases/download/v${version}/actual-upload.zip`};
async function render(data, ok = true) {
  const buttons = Array.from({length: 2}, () => ({attrs: {'aria-disabled': 'true', tabindex: '-1'}, removeAttribute(name) {delete this.attrs[name];}}));
  const note = {textContent: 'No public release yet'};
  const requests = [];
  vm.runInNewContext(source, {
    URL, document: {currentScript: {src: 'https://example.org/sub/download.js'}, querySelectorAll: () => buttons, querySelector: () => note},
    fetch: async (...args) => {requests.push(args); return {ok, json: async () => data};}
  });
  await new Promise(resolve => setImmediate(resolve));
  return {buttons, note, requests};
}
test('all CTAs resolve the single relative metadata file', async () => {
  const result = await render(valid);
  assert.equal(result.requests.length, 1);
  assert.equal(String(result.requests[0][0]), 'https://example.org/sub/release.json');
  for (const button of result.buttons) {assert.equal(button.href, valid.downloadURL); assert.deepEqual(button.attrs, {});}
});
test('stable releases work without changing the controller', async () => {
  const stable = {version: '1.0.0', channel: 'stable', downloadURL: valid.downloadURL.replaceAll('-beta.1', '')};
  assert.equal((await render(stable)).buttons[0].href, stable.downloadURL);
});
test('placeholder, malformed data, failed requests, and temporary URLs stay disabled', async () => {
  for (const [data, ok] of [[{version:null, channel:null, downloadURL:null}, true], [valid, false], [null, true], [{...valid, channel:'stable'}, true], [{...valid, downloadURL:'https://temporary.example/archive.zip'}, true], [{...valid, downloadURL:valid.downloadURL + '?token=fixture'}, true]]) {
    for (const button of (await render(data, ok)).buttons) {assert.equal(button.href, undefined); assert.equal(button.attrs['aria-disabled'], 'true');}
  }
});
test('HTML download links have no hardcoded target and metadata is valid', () => {
  const html = readFileSync(resolve(root, 'index.html'), 'utf8');
  const buttons = html.match(/<a\b[^>]*data-download[^>]*>/g);
  assert.equal(buttons.length, 2);
  for (const button of buttons) {assert.ok(!/\bhref=/.test(button)); assert.match(button, /aria-disabled="true"/);}
  assert.match(html, /src="download.js" defer/);
  const metadata = JSON.parse(readFileSync(resolve(root, 'release.json'), 'utf8'));
  assert.deepEqual(Object.keys(metadata).sort(), ['channel','downloadURL','version']);
  assert.ok(Object.values(metadata).every(value => value === null) || (typeof metadata.version === 'string' && ['stable', 'beta'].includes(metadata.channel) && typeof metadata.downloadURL === 'string'));
});
