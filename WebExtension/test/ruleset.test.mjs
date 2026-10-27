import assert from 'node:assert/strict';
import { test } from 'node:test';
import { lookup, parentDomains } from '../src/ruleset.js';

const ruleset = {
  entries: [
    { t: 'scriptlet', c: 'set-constant', a: ['ads', 'false'] },          // 0 example.com
    { t: 'css', c: 'body { overflow: auto !important; }' },              // 1 example.com
    { t: 'ext', c: 'div:has-text(Ad) { display: none !important; }' },   // 2 generic
    { t: 'ext', c: '.promo { display: none !important; }', x: ['safe.com'] }, // 3 generic
    { t: 'js', c: 'window.x = 1' },                                      // 4 example.com
    { t: 'scriptlet', c: 'prevent-fetch', a: ['ads.js'] },               // 5 example.com
  ],
  rules: { '': [2, 3], 'example.com': [0, 1, 4, 5] },
  exceptions: {
    'news.example.com': [{ t: 'scriptlet', c: 'prevent-fetch', a: [] }],
    'clean.example.com': [{ t: 'ext', c: 'div:has-text(Ad) { display: none !important; }' }],
  },
  pages: {
    'bank.com': ['all'],
    'shop.example.com': ['generichide'],
    'nojs.example.com': ['jsinject'],
  },
};

test('parentDomains walks up to the TLD', () => {
  assert.deepEqual(parentDomains('a.b.example.com'), ['a.b.example.com', 'b.example.com', 'example.com', 'com']);
});

test('subdomains get domain and generic rules', () => {
  const r = lookup(ruleset, 'www.example.com');
  assert.deepEqual(r.scriptlets, [{ name: 'set-constant', args: ['ads', 'false'] }, { name: 'prevent-fetch', args: ['ads.js'] }]);
  assert.deepEqual(r.css, ['body { overflow: auto !important; }']);
  assert.equal(r.ext.length, 2);
  assert.deepEqual(r.js, ['window.x = 1']);
});

test('excluded domains and exceptions', () => {
  assert.equal(lookup(ruleset, 'safe.com').ext.length, 1);
  assert.deepEqual(lookup(ruleset, 'news.example.com').scriptlets.map((s) => s.name), ['set-constant']);
  assert.deepEqual(lookup(ruleset, 'clean.example.com').ext, ['.promo { display: none !important; }']);
});

test('page flags', () => {
  assert.deepEqual(lookup(ruleset, 'www.bank.com'), { css: [], ext: [], scriptlets: [], js: [] });
  // An iframe inside an allowlisted page is allowlisted too.
  assert.equal(lookup(ruleset, 'example.com', 'bank.com').scriptlets.length, 0);
  const shop = lookup(ruleset, 'shop.example.com');
  assert.equal(shop.ext.length, 0);
  assert.equal(shop.css.length, 1);
  const nojs = lookup(ruleset, 'nojs.example.com');
  assert.equal(nojs.scriptlets.length + nojs.js.length, 0);
});

test('real ruleset (optional): OPENBLOCK_RULESET=path', { skip: !process.env.OPENBLOCK_RULESET }, async () => {
  const { readFileSync } = await import('node:fs');
  const real = JSON.parse(readFileSync(process.env.OPENBLOCK_RULESET, 'utf8'));
  const started = performance.now();
  const yt = lookup(real, 'www.youtube.com');
  const elapsed = performance.now() - started;
  assert.ok(yt.scriptlets.length > 0, 'youtube has scriptlets');
  assert.ok(elapsed < 20, `lookup took ${elapsed}ms`);
});
