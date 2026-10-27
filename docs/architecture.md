# OpenBlock architecture

An open-source Safari ad blocker for macOS, modelled on how AdGuard for Safari works.

## 1. How AdGuard for Safari works (what we are copying)

Safari does **not** let extensions inspect or cancel network requests in code. Every
Safari ad blocker, AdGuard included, is built on Apple's **Content Blocker** API:

1. A **host macOS app** downloads text filter lists (AdBlock/uBlock/AdGuard syntax such as
   `||ads.example.com^$third-party` or `example.com##.banner`).
2. A **converter** translates each text rule into Safari's declarative JSON format
   (`{"trigger": {...}, "action": {...}}`). AdGuard's converter is the open-source
   `SafariConverterLib`.
3. The JSON is written to a shared **App Group** container.
4. The app calls `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)`.
5. Safari launches the tiny **content-blocker extension**. The extension returns the JSON file.
   Safari compiles it into a bytecode state machine and runs it inside WebKit. The app does not
   need to stay running.

Constraints that shape the whole design:

| Constraint | Consequence |
|---|---|
| Max **150,000 rules per content blocker** (Safari 15+) | AdGuard ships **6 content blockers** (General, Privacy, Social, Security, Other, Custom) and spreads the filter lists across them. |
| Blockers are **independent**: an exception in blocker A cannot unblock a rule in blocker B | Exceptions that must cross blockers are duplicated. AdGuard's Safari lists mark these with `!#safari_cb_affinity(privacy)…!#safari_cb_affinity` blocks. The allowlist is appended to *every* blocker. |
| Rule order matters; `ignore-previous-rules` cancels everything **above** it | The converter emits rules in a fixed order (see §3). |
| Regex subset only: `.` `*` `+` `?` `[]` `()` `^` `$`. No `\|`, `{n}`, `\d`, or look-around | Some rules cannot be converted and are skipped. |
| One bad CSS selector invalidates the whole batched rule | Selectors are validated and batched carefully. |
| Content blockers cannot run JavaScript or inject CSS styles | Scriptlets (`#%#//scriptlet`), CSS injection (`#$#`), and extended CSS (`#?#`) need a **separate Safari Web Extension**. AdGuard calls it "AdGuard Advanced Blocking". This is Phase 2. |

The Safari-specific AdGuard lists at `https://filters.adtidy.org/extension/safari/filters/<id>.txt`
are already preprocessed (no `!#if` blocks) and tuned for Safari. In the sampled Base list,
about 10k of 153k lines were advanced rules that need Phase 2.

## 2. Architecture

```
OpenBlock.app (SwiftUI, sandboxed)
 ├─ FilterManager: download → BlockerCore.convert → write JSON → reload blockers
 ├─ UI: list toggles, custom rules, allowlist, per-blocker status
 └─ PlugIns/
     ├─ OpenBlock Ads.appex        (content blocker, reads ads.json)
     ├─ OpenBlock Privacy.appex    (content blocker, reads privacy.json)
     ├─ OpenBlock Annoyances.appex (content blocker, reads annoyances.json)
     └─ OpenBlock Custom.appex     (content blocker, reads custom.json)

Packages/BlockerCore (Swift package, no UI, unit-tested)
 ├─ RuleParser     text line → FilterRule (network / cosmetic / unsupported)
 ├─ Converter      [FilterRule] → ordered [SafariRule] + statistics
 ├─ ListParser     handles !#if / !#safari_cb_affinity directives
 └─ obconvert CLI  converts a list and verifies it with WKContentRuleListStore
                   (the same WebKit compiler that Safari uses)

Shared App Group: 9YQSNGHYX6.de.hamou.openblock
 └─ Rules/{ads,privacy,annoyances,custom}.json  + state.json
```

One extension source file is compiled into four targets. Each target reads its JSON file name
from `Info.plist` (`OBRulesFile`).

## 3. Converter rule order (per blocker)

1. Generic element hiding (`##.ad`), with selectors batched into groups
2. `$generichide` exceptions → `ignore-previous-rules` on the page domain
3. Domain-specific element hiding (`example.com##.ad`)
4. `$elemhide` exceptions
5. Network blocking rules (`||ads.com^$third-party,script`)
6. Network exceptions (`@@||cdn.com/ads.js`)
7. `$important` blocking rules (these override normal exceptions)
8. `$important` exceptions and `$document` exceptions, which includes the user's allowlist

`#@#` cosmetic exceptions are resolved at conversion time: the generic selector gets
`unless-domain`, and a domain rule is dropped. `$badfilter` removes the rule it targets.

## 4. Phases

### Phase 1 — Content blockers (implemented in this repo)
- [x] BlockerCore converter for network rules: anchors, wildcards, `^` separator, regex rules,
      `$domain`, `$third-party`/`$first-party`, resource types, `$match-case`, `$popup`,
      `$important`, `$badfilter`, `$document`, `$elemhide`, `$generichide`
- [x] Cosmetic `##`, `#@#`, generic and domain-specific
- [x] `!#if/!#else/!#endif` and `!#safari_cb_affinity` routing
- [x] Unit tests and a CLI that verifies output with WebKit's real compiler
- [x] macOS app: filter catalog, download, convert, reload, custom rules, allowlist, auto-update
- [x] Blocking `$document` rules (`resource-type: document`, `load-context: top-frame`) and hosts-file lists
- [x] Menu bar item (status, update, pause), Dock icon only while the window is open, launch at login
- [x] Four content-blocker extensions sharing one App Group

### Phase 2 — "OpenBlock Advanced" Safari Web Extension (implemented)

```
App ──AdvancedCompiler──▶ Rules/advanced.json (App Group)
                               │  native messaging: { action: "getRuleset", version }
                               ▼
     background.js (service worker) ── caches ruleset; refreshes every 5 min if the file changed
         ▲  getRules(url)                  │ scripting.executeScript(world: MAIN)  → scriptlets
         │                                 │ scripting.insertCSS(origin: USER)     → #$# CSS
     content.js (document_start, all frames) ─ ExtendedCss → #?#, :has-text(), :remove() …
                                             └ <script>/<style> fallback when the APIs above fail
```

- [x] `AdvancedCompiler` (Swift): parses `#$#`, `#$?#`, `#?#`, extended `##`, `#%#//scriptlet()`,
      `##+js()`, raw `#%#` JS, all `#@…#` exceptions, and `$document/$elemhide/$generichide/$jsinject`
      page exceptions plus the allowlist. Rules are stored once and indexed by domain
      (about 10.5k rules from AdGuard Base, Tracking and EasyList come to 1.7 MB).
- [x] Security: raw JS and `trusted-*` scriptlets are accepted only from built-in lists and user rules;
      CSS injections containing `url()`/`@import` are dropped.
- [x] Scriptlets run through `scripting.executeScript({ world: "MAIN", func })`, so page CSP cannot block them.
      uBO aliases (`aopr`, `nostif` …) are resolved by the AdGuard library.
- [x] Tests: Swift (`swift test`) and JS (`npm test`), which runs minified scriptlets in jsdom.
- [ ] `$redirect` / `$removeparam` via `declarativeNetRequest`
- [x] Wildcard-TLD domains (`example.*`): the extension indexes them and matches hostnames through the public
      suffix list (`tldts`). Plain `example.*##.ad` rules also run here, since Safari's `if-domain` cannot match them

### Phase 3 — Polish
- Safari toolbar popup for OpenBlock Advanced with a "disable on this site" toggle (the app already has a global pause)
- Incremental list updates (`! Diff-Path:` patches) to save bandwidth
- Element picker: click an element in Safari to create a hiding rule
- Rule hit statistics (not possible with content blockers alone; needs Phase 2)

### Phase 4 — Blocking outside Safari
Safari content blockers and web extensions only run inside Safari. The practical way to block ad and
tracker domains in every app is a DNS configuration installed with `NEDNSSettingsManager` that points
macOS to a filtering resolver (AdGuard DNS or NextDNS over HTTPS). It needs the "DNS Settings"
Network Extension capability on the App ID and cannot hide page elements or stop YouTube ads.

## 5. Build & enable

```bash
cd ~/Developer/OpenBlock
xcodegen generate
open OpenBlock.xcodeproj    # Run the "OpenBlock" scheme
```
Then go to Safari → Settings → Extensions and enable the four "OpenBlock …" blockers.
Locally built extensions also need *Develop → Allow Unsigned Extensions*, unless they are signed
with your team. They are signed with your team in this project.

## 6. Licensing notes
- OpenBlock code: GPL-3.0 (see LICENSE). The converter is a reimplementation; OpenBlock Advanced bundles AdGuard's GPL-3 Scriptlets and ExtendedCss.
- Filter lists are downloaded at runtime and keep their own licenses (AdGuard filters: GPL-3/CC-BY-SA; EasyList: GPL-3/CC-BY-SA).
