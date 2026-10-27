// Scriptlets are sent to the page as source text (scripting.executeScript serializes `func`),
// so each function must stay self-contained after esbuild minifies the background bundle.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';

const bundle = await build({
  stdin: {
    contents: "export { scriptlets, SCRIPTLETS_VERSION } from '@adguard/scriptlets';",
    resolveDir: new URL('..', import.meta.url).pathname,
  },
  bundle: true, format: 'esm', minify: true, target: ['safari16'], write: false,
});
const { scriptlets, SCRIPTLETS_VERSION } = await import(
  `data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString('base64')}`
);

function runInPage(name, args) {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', { runScripts: 'outside-only' });
  const fn = scriptlets.getScriptletFunction(name);
  assert.equal(typeof fn, 'function', `${name} exists`);
  const source = { name, args, engine: 'extension', version: SCRIPTLETS_VERSION, verbose: false };
  // Same as executeScript({ func, args }): rebuild the function from its text in the page.
  dom.window.eval(`(${fn.toString()})(${JSON.stringify(source)}, ${JSON.stringify(args)})`);
  return dom.window;
}

test('set-constant works after minification', () => {
  const window = runInPage('set-constant', ['adsEnabled', 'false']);
  assert.equal(window.eval('window.adsEnabled'), false);
});

test('abort-on-property-read throws on access', () => {
  const window = runInPage('abort-on-property-read', ['adblockDetector']);
  assert.throws(() => window.eval('window.adblockDetector'));
});

test('uBO aliases resolve', () => {
  for (const name of ['ubo-aopr.js', 'aopr.js', 'ubo-set.js', 'ubo-nostif.js']) {
    assert.equal(typeof scriptlets.getScriptletFunction(name), 'function', name);
  }
});
