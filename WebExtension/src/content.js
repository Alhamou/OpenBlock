// OpenBlock Advanced — content script, runs at document_start in every frame.
// Asks the background for this frame's rules, then applies ExtendedCss rules and any
// scripts or CSS the background could not inject itself.

import { ExtendedCss } from '@adguard/extended-css';

/** URL used for rule matching; about:blank and srcdoc frames inherit their parent's. */
function frameUrl() {
  if (/^https?:/.test(window.location.href)) return window.location.href;
  try {
    return window.parent.location.href;
  } catch {
    return document.referrer || window.location.href;
  }
}

function injectScript(code) {
  const script = document.createElement('script');
  script.textContent = code;
  (document.head || document.documentElement).appendChild(script);
  script.remove();
}

function injectStyle(css) {
  const style = document.createElement('style');
  style.textContent = css;
  (document.head || document.documentElement).appendChild(style);
}

/** Self-test hook: TestPages/advanced.html (served from localhost) shows this status. */
function reportStatus(status) {
  if (window.location.hostname !== 'localhost' || window !== window.top) return;
  whenDocumentElement(() => { document.documentElement.dataset.openblock = status; });
}

function whenDocumentElement(callback) {
  if (document.documentElement) {
    callback();
    return;
  }
  const observer = new MutationObserver(() => {
    if (!document.documentElement) return;
    observer.disconnect();
    callback();
  });
  observer.observe(document, { childList: true });
}

async function main() {
  if (window.__openblockAdvanced) return;
  window.__openblockAdvanced = true;

  reportStatus('content script started');
  const url = frameUrl();
  if (!/^https?:/.test(url)) return;

  let rules;
  try {
    rules = await browser.runtime.sendMessage({ type: 'getRules', url });
  } catch (error) {
    reportStatus(`message failed: ${error}`);
    return;
  }
  if (!rules) {
    reportStatus('no response');
    return;
  }
  if (rules.paused) {
    // The user paused OpenBlock Advanced on this site from the toolbar popup.
    reportStatus('paused on this site');
    return;
  }
  reportStatus(rules.error ? `background error: ${rules.error}`
    : `ok css=${rules.css?.length} ext=${rules.ext?.length} scripts=${rules.scripts?.length}`);

  whenDocumentElement(() => {
    for (const code of rules.scripts || []) injectScript(code);
    if (rules.css?.length) injectStyle(rules.css.join('\n'));
    if (rules.ext?.length) {
      try {
        new ExtendedCss({ cssRules: rules.ext }).apply();
      } catch (error) {
        console.warn('OpenBlock: ExtendedCss failed', error);
      }
    }
  });
}

main();
