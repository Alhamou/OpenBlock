// OpenBlock Advanced — toolbar popup.
// Shows the active tab's hostname, whether OpenBlock Advanced is blocking there, and a
// "Pause on this site" toggle. The background worker owns the paused-site list; the popup
// only asks for the status and sends `setPaused`, then reloads the tab so the change applies.

const $ = (id) => document.getElementById(id);

function t(key, fallback) {
  try {
    return browser.i18n.getMessage(key) || fallback;
  } catch {
    return fallback;
  }
}

for (const node of document.querySelectorAll('[data-i18n]')) {
  node.textContent = t(node.dataset.i18n, node.textContent);
}

function setStatus(kind, text) {
  const status = $('status');
  status.className = `status ${kind}`;
  status.textContent = text;
}

function render(state) {
  $('hostname').textContent = state.hostname || t('popup_no_site', 'No website');
  $('toggle-row').hidden = !state.supported;
  $('pause').checked = Boolean(state.paused);
  $('rules').textContent = '';

  if (!state.supported) {
    setStatus('', t('popup_status_inactive', 'Inactive'));
    $('detail').textContent = t('popup_not_a_website', 'OpenBlock only works on web pages.');
    return;
  }
  if (state.paused) {
    setStatus('off', t('popup_status_paused', 'Paused'));
    $('detail').textContent = t('popup_paused_detail', 'Advanced rules are off on this site.');
    return;
  }
  if (!state.rulesetLoaded) {
    setStatus('', t('popup_status_loading', 'Loading'));
    $('detail').textContent = t('popup_loading_detail', 'Waiting for the rules from the OpenBlock app.');
    return;
  }
  setStatus('on', t('popup_status_active', 'Active'));
  const total = state.counts.css + state.counts.ext + state.counts.scriptlets + state.counts.js;
  $('detail').textContent = total
    ? t('popup_active_detail', 'Advanced rules are applied on this site.')
    : t('popup_no_rules_detail', 'No advanced rules for this site. Content blockers still apply.');
  $('rules').textContent = total
    ? `${state.counts.scriptlets} scriptlets · ${state.counts.css + state.counts.ext} CSS · ${state.counts.js} scripts`
    : '';
}

async function activeTab() {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function main() {
  let tab;
  try {
    tab = await activeTab();
  } catch {
    tab = undefined;
  }
  const url = tab?.url || '';

  let state;
  try {
    state = await browser.runtime.sendMessage({ type: 'getStatus', url });
  } catch (error) {
    state = { supported: false, hostname: '', error: String(error) };
  }
  if (!state) state = { supported: false, hostname: '' };
  render(state);

  $('pause').addEventListener('change', async (event) => {
    const paused = event.target.checked;
    $('pause').disabled = true;
    try {
      const next = await browser.runtime.sendMessage({ type: 'setPaused', hostname: state.hostname, paused });
      render({ ...state, ...next });
      if (tab?.id !== undefined) await browser.tabs.reload(tab.id);
      window.close();
    } catch (error) {
      $('detail').textContent = String(error);
    } finally {
      $('pause').disabled = false;
    }
  });
}

main();
