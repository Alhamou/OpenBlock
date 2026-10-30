// Per-site pause, shared by the background worker and the popup.
// The list of paused hostnames lives in browser.storage.local under `pausedSites`.
// A paused hostname also covers its subdomains: pausing `example.com` pauses `www.example.com`.

import { parentDomains } from './ruleset.js';

export const STORAGE_KEY = 'pausedSites';

/** @param {Iterable<string>} pausedSites @param {string} hostname */
export function isPaused(pausedSites, hostname) {
  if (!hostname) return false;
  const paused = pausedSites instanceof Set ? pausedSites : new Set(pausedSites);
  return parentDomains(hostname).some((domain) => paused.has(domain));
}

/** Returns a new list with `hostname` paused or resumed (resuming also drops parent entries). */
export function withPaused(pausedSites, hostname, paused) {
  const host = hostname.toLowerCase().replace(/\.$/, '');
  const next = new Set(pausedSites);
  if (paused) {
    next.add(host);
  } else {
    for (const domain of parentDomains(host)) next.delete(domain);
  }
  return [...next].sort();
}

export async function loadPausedSites() {
  try {
    const stored = await browser.storage.local.get(STORAGE_KEY);
    const list = stored?.[STORAGE_KEY];
    return Array.isArray(list) ? list.filter((item) => typeof item === 'string') : [];
  } catch {
    return [];
  }
}

export function savePausedSites(list) {
  return browser.storage.local.set({ [STORAGE_KEY]: list });
}
