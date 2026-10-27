// OpenBlock Advanced — background service worker.
//
// 1. Fetches the advanced ruleset from the host app through native messaging
//    (SafariWebExtensionHandler reads Rules/advanced.json from the App Group).
// 2. Answers each content script's `getRules` request for its frame.
// 3. Runs scriptlets in the page's main world with scripting.executeScript, which page CSP
//    cannot block, and injects CSS as a user stylesheet with scripting.insertCSS.
//    When either API fails, the code is handed back to the content script as a fallback.

import { scriptlets, SCRIPTLETS_VERSION } from '@adguard/scriptlets';
import { lookup } from './ruleset.js';

const APP_ID = 'de.hamou.openblock';
const REFRESH_INTERVAL_MS = 5 * 60 * 1000;

let ruleset = null;
let rulesetVersion = null;
let lastFetch = 0;
let pending = null;

async function fetchRuleset() {
  const reply = await browser.runtime.sendNativeMessage(APP_ID, { action: 'getRuleset', version: rulesetVersion });
  lastFetch = Date.now();
  if (reply?.ruleset) {
    ruleset = JSON.parse(reply.ruleset);
    rulesetVersion = reply.version;
  }
}

/** Returns the cached ruleset at once and refreshes it in the background when it is stale. */
async function currentRuleset() {
  const stale = Date.now() - lastFetch > REFRESH_INTERVAL_MS;
  if (!pending && (ruleset === null || stale)) {
    pending = fetchRuleset()
      .catch((error) => console.warn('OpenBlock: could not load advanced rules', error))
      .finally(() => { pending = null; });
  }
  if (ruleset === null && pending) await pending;
  return ruleset;
}

function hostnameOf(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

/** Resolves a scriptlet name, accepting uBO aliases (`ubo-aopr.js`, `aopr.js`, `aopr`). */
function scriptletFunction(name) {
  for (const candidate of [name, name.replace(/^ubo-/, ''), name.replace(/\.js$/, '')]) {
    const fn = scriptlets.getScriptletFunction(candidate);
    if (typeof fn === 'function') return { name: candidate, fn };
  }
  return null;
}

function scriptletSource(name, args, hostname) {
  return {
    name,
    args,
    engine: 'extension',
    version: SCRIPTLETS_VERSION,
    verbose: false,
    domainName: hostname,
    uniqueId: 'openblock',
  };
}

/** Returns the code of scriptlets that could not be executed directly. */
async function runScriptlets(target, list, hostname) {
  const fallback = [];
  await Promise.all(list.map(async ({ name, args }) => {
    const resolved = scriptletFunction(name);
    if (!resolved) return;
    const source = scriptletSource(resolved.name, args, hostname);
    try {
      await browser.scripting.executeScript({
        target,
        world: 'MAIN',
        injectImmediately: true,
        func: resolved.fn,
        args: [source, args],
      });
    } catch {
      try {
        fallback.push(scriptlets.invoke(source));
      } catch {
        // Unknown scriptlet: ignore.
      }
    }
  }));
  return fallback;
}

async function insertCss(target, css) {
  if (!css.length) return true;
  try {
    await browser.scripting.insertCSS({ target, css: css.join('\n'), origin: 'USER' });
    return true;
  } catch {
    return false;
  }
}

// Scriptlets must run before the page's own scripts, so they are injected as soon as the
// navigation commits rather than when the content script asks. Each frame's injection is
// memoized by URL; the content script's request then reuses it. Scriptlets also guard
// themselves against running twice (`uniqueId`), so an occasional double injection is harmless.
const injections = new Map(); // `${tabId}:${frameId}` → { url, done }

function inject(tabId, frameId, url, topUrl) {
  const key = `${tabId}:${frameId}`;
  const existing = injections.get(key);
  if (existing && existing.url === url) return existing.done;

  const done = (async () => {
    const hostname = hostnameOf(url);
    const rules = lookup(await currentRuleset(), hostname, hostnameOf(topUrl) || hostname);
    const target = { tabId, frameIds: [frameId] };
    const [fallbackScripts, cssInserted] = await Promise.all([
      runScriptlets(target, rules.scriptlets, hostname),
      insertCss(target, rules.css),
    ]);
    return { rules, fallbackScripts, css: cssInserted ? [] : rules.css };
  })();
  injections.set(key, { url, done });
  return done;
}

browser.webNavigation.onCommitted.addListener(({ tabId, frameId, url }) => {
  if (tabId < 0 || !/^https?:/.test(url)) return;
  const topUrl = frameId === 0 ? Promise.resolve(url) : browser.tabs.get(tabId).then((tab) => tab.url, () => url);
  topUrl.then((top) => inject(tabId, frameId, url, top)).catch(() => {});
});

browser.tabs.onRemoved.addListener((tabId) => {
  for (const key of injections.keys()) if (key.startsWith(`${tabId}:`)) injections.delete(key);
});

async function handleGetRules(message, sender) {
  const tabId = sender.tab?.id;
  const hostname = hostnameOf(message.url);
  const topHostname = hostnameOf(sender.tab?.url || message.url) || hostname;

  if (tabId !== undefined) {
    const injected = await inject(tabId, sender.frameId ?? 0, message.url, sender.tab?.url);
    return {
      css: injected.css,
      ext: injected.rules.ext,
      scripts: [...injected.fallbackScripts, ...injected.rules.js],
    };
  }

  // No tab (should not happen in Safari): hand everything to the content script.
  const rules = lookup(await currentRuleset(), hostname, topHostname);
  const scriptletCode = rules.scriptlets.map(({ name, args }) => {
    const resolved = scriptletFunction(name);
    return resolved ? scriptlets.invoke(scriptletSource(resolved.name, args, hostname)) : '';
  }).filter(Boolean);
  return { css: rules.css, ext: rules.ext, scripts: [...scriptletCode, ...rules.js] };
}

// sendResponse + `return true` works in every Safari version; returning a Promise does not.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'getRules') return false;
  handleGetRules(message, sender)
    .then(sendResponse)
    .catch((error) => sendResponse({ error: String(error), css: [], ext: [], scripts: [] }));
  return true;
});

// Warm the cache as soon as the worker starts.
currentRuleset();
