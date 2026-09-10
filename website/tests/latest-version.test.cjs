const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const vm = require('node:vm');
const source = readFileSync(resolve(__dirname, '../latest-version.js'), 'utf8');
async function render(pages, lazy = false) {
  const label = {textContent:'', available:false, classList:{add() {label.available = true;}}, removeAttribute() {}};
  const requests = [];
  let callback;
  const context = {
    document:{querySelector(selector) {assert.equal(selector, '[data-latest-version]'); return label;}},
    window: {}, AbortController, setTimeout, clearTimeout,
    fetch: async (url, options) => {
      requests.push({url, options});
      const data = pages[Math.min(requests.length - 1, pages.length - 1)];
      if (data instanceof Error) throw data;
      return {ok:data !== false, json:async () => data};
    }
  };
  if (lazy) {
    context.window.IntersectionObserver = true;
    context.IntersectionObserver = class {constructor(cb) {callback = cb;} observe() {} disconnect() {}};
  }
  vm.runInNewContext(source, context);
  const settle = () => new Promise(resolve => setImmediate(resolve));
  await settle();
  return {label, requests, reveal:async () => {callback([{isIntersecting:true}]); await settle();}};
}
const tags = (...names) => names.map(name => ({name}));
test('sorts numeric semantic versions rather than API order', async () => {
  for (const [names, expected] of [
    [['v1.0.1-beta.1'], 'v1.0.1 Beta 1'],
    [['v1.0.1-beta.12'], 'v1.0.1 Beta 12'],
    [['v1.9.9', 'v1.10.0', 'v1.2.0'], 'v1.10.0'],
    [['v1.0.1-beta.2', 'v1.0.1-beta.10', 'v1.0.1-beta.0'], 'v1.0.1 Beta 10'],
    [['v1.0.1-beta.99', 'v1.0.1'], 'v1.0.1'],
    [['v1.0.1', 'v2.0.0-beta.1'], 'v2.0.0 Beta 1']
  ]) assert.equal((await render([tags(...names)])).label.textContent, expected);
});
test('rejects malformed tags and ignores unrelated tag formats', async () => {
  const result = await render([tags('v01.0.0', '1.0.0', 'v9.0.0-rc.1', 'v9.0.0-beta.01', 'v9.0.0\n', 'v1.0.0')]);
  assert.equal(result.label.textContent, 'v1.0.0');
});
test('checks subsequent pages and sends no credentials', async () => {
  const result = await render([Array(100).fill({name:'v1.0.0'}), tags('v3.0.0')]);
  assert.equal(result.label.textContent, 'v3.0.0');
  assert.equal(result.requests[1].url, 'https://api.github.com/repos/T-1234567890/origami-browser/tags?per_page=100&page=2');
  assert.equal(result.requests[0].options.credentials, 'omit');
  assert.equal(result.requests[0].options.referrerPolicy, 'no-referrer');
});
test('API failure, malformed responses, no valid tags and incomplete pagination hide quietly', async () => {
  for (const pages of [[false], [new Error('offline')], [{}], [[]], [tags('irrelevant')], [Array(100).fill({name:'v1.0.0'})]]) {
    const result = await render(pages);
    assert.equal(result.label.available, false);
    assert.equal(result.label.textContent, '');
    assert.ok(result.requests.length <= 10);
  }
});
test('waits until the final CTA approaches the viewport', async () => {
  const result = await render([tags('v1.0.0')], true);
  assert.equal(result.requests.length, 0);
  await result.reveal();
  assert.equal(result.label.textContent, 'v1.0.0');
  assert.equal(result.label.available, true);
});
