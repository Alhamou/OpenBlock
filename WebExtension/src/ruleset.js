// Looks up the advanced rules that apply to a page. The ruleset is produced by
// BlockerCore's AdvancedCompiler (Swift) and has this shape:
//
//   entries:    [{ t: 'css'|'ext'|'scriptlet'|'js', c: text-or-name, a?: args, x?: excludedDomains }]
//   rules:      { 'example.com': [entryIndex, ...], '': [generic entry indices] }
//   exceptions: { 'example.com': [entry, ...], '': [...] }  // #@#, #@$#, #@%# rules
//   pages:      { 'example.com': ['all'|'elemhide'|'generichide'|'jsinject'] }

/** `a.b.example.com` → ['a.b.example.com', 'b.example.com', 'example.com', 'com'] */
export function parentDomains(hostname) {
  const parts = hostname.toLowerCase().replace(/\.$/, '').split('.');
  return parts.map((_, i) => parts.slice(i).join('.'));
}

function matchesAnyDomain(domains, candidates) {
  return domains.some((d) => candidates.includes(d));
}

function entryKey(entry) {
  return entry.t === 'scriptlet' ? `${entry.c}\u0000${(entry.a || []).join('\u0000')}` : `${entry.t}\u0000${entry.c}`;
}

/**
 * @param {object} ruleset
 * @param {string} hostname  hostname of the frame
 * @param {string} [topHostname]  hostname of the tab, used for page-level switches
 * @returns {{ css: string[], ext: string[], scriptlets: {name: string, args: string[]}[], js: string[] }}
 */
export function lookup(ruleset, hostname, topHostname = hostname) {
  const result = { css: [], ext: [], scriptlets: [], js: [] };
  if (!ruleset || !hostname) return result;

  const domains = parentDomains(hostname);
  const flags = new Set();
  for (const host of new Set([...domains, ...parentDomains(topHostname || hostname)])) {
    for (const flag of ruleset.pages?.[host] || []) flags.add(flag);
  }
  if (flags.has('all')) return result;

  // Exceptions: exact rule text (or scriptlet name + args) on this domain or everywhere.
  const disabled = new Set();
  const disabledScriptletNames = new Set();
  let allScriptletsDisabled = false;
  for (const key of ['', ...domains]) {
    for (const entry of ruleset.exceptions?.[key] || []) {
      if (entry.t === 'scriptlet' && !(entry.a && entry.a.length)) {
        if (entry.c === '') allScriptletsDisabled = true;
        else disabledScriptletNames.add(entry.c);
      } else {
        disabled.add(entryKey(entry));
      }
    }
  }

  const seen = new Set();
  for (const key of ['', ...domains]) {
    const generic = key === '';
    for (const index of ruleset.rules?.[key] || []) {
      if (seen.has(index)) continue;
      seen.add(index);
      const entry = ruleset.entries[index];
      if (entry.x && matchesAnyDomain(entry.x, domains)) continue;
      if (disabled.has(entryKey(entry))) continue;

      switch (entry.t) {
        case 'css':
        case 'ext':
          if (flags.has('elemhide') || (generic && flags.has('generichide'))) break;
          result[entry.t].push(entry.c);
          break;
        case 'scriptlet':
          if (flags.has('jsinject') || allScriptletsDisabled || disabledScriptletNames.has(entry.c)) break;
          result.scriptlets.push({ name: entry.c, args: entry.a || [] });
          break;
        case 'js':
          if (!flags.has('jsinject')) result.js.push(entry.c);
          break;
        default:
          break;
      }
    }
  }
  return result;
}
