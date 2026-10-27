# OpenBlock

An open-source ad blocker for Safari on macOS, built the same way as AdGuard for Safari:
filter lists → converter → Safari content blockers.

- **4 Safari content blockers**: Ads, Privacy, Annoyances, Custom. Each has its own 150k-rule budget.
- **Real filter lists**: AdGuard Base/Tracking/Social/Cookie/Popups (Safari builds), EasyList, EasyPrivacy, regional lists, or any URL you add (AdBlock syntax or hosts files).
- **User rules and an allowlist**, in AdBlock syntax.
- **OpenBlock Advanced**, a Safari Web Extension for the rules content blockers can't express:
  scriptlets (`#%#//scriptlet(...)`, uBO `##+js(...)`), CSS injection (`#$#`), extended CSS
  (`#?#`, `:has-text()`, `:remove()` …) and rules on wildcard-TLD domains (`example.*`).
  Examples are YouTube ads and anti-adblock walls.
- **Lives in the menu bar**: status, *Update Filters Now*, *Pause Blocking*, *Launch at Login*. The Dock
  icon only shows while the OpenBlock window is open (Settings → "Keep OpenBlock in the menu bar only").
- **Auto-update** every 24 hours while OpenBlock is running (in the menu bar is enough).

OpenBlock blocks only inside Safari. Safari compiles the rules into its own engine; other browsers and
apps never see them. See [docs/PLAN.md](docs/PLAN.md) for how it works and the roadmap, including
DNS-based blocking for every app.

## Build

Requirements: macOS 15+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open OpenBlock.xcodeproj   # run the "OpenBlock" scheme
```

or from the terminal:

```bash
xcodebuild -project OpenBlock.xcodeproj -scheme OpenBlock -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/OpenBlock.app
```

Keep one copy of the app on disk: Safari gets confused when two builds register the same extensions.

To use a different Apple team, change `DEVELOPMENT_TEAM` in `project.yml`.
The App Group ID is derived from it.

Then go to **Safari → Settings → Extensions** and:
1. enable the four **OpenBlock** content blockers;
2. enable **OpenBlock Advanced**, then click its icon in Safari's toolbar and choose
   *Always Allow on Every Website*.

Development builds: every rebuild changes the extension's signature, and Safari then turns
OpenBlock Advanced off and drops its website permission. Re-enable it after each build.

Self-test: `python3 -m http.server 8765 --directory TestPages`, add `TestPages/rules.txt` to
User Rules, and open http://localhost:8765/advanced.html in Safari.

OpenBlock reloads each blocker as soon as you come back to the app. Toggling or adding lists shows an
*Apply Changes* button; it downloads only lists that are new.

The web extension's JavaScript is built from `WebExtension/` into `Extensions/Advanced/Resources`
(the built files are committed, so Xcode doesn't need Node):

```bash
cd WebExtension
npm install
npm test
npm run build
```

## Layout

| Path | What |
|---|---|
| `Packages/BlockerCore` | Rule parser + Safari converter (pure Swift, unit-tested) and the `obconvert` CLI |
| `App/` | SwiftUI host app: downloads, converts, writes JSON, reloads blockers; menu bar item and settings |
| `Extensions/ContentBlocker` | One request handler compiled into the four blocker extensions |
| `Extensions/Advanced` | OpenBlock Advanced web extension: native handler + built JS bundle |
| `WebExtension/` | Source of the web extension (background worker, content script, rule lookup, tests) |
| `Shared/` | App Group paths used by the app and the extensions |

## Converter CLI

```bash
cd Packages/BlockerCore
swift test
swift run -c release obconvert easylist.txt --out rules.json --verify
```

`--verify` compiles the output with `WKContentRuleListStore`, the same compiler Safari uses.

## License

GPL-3.0 (see LICENSE), because OpenBlock Advanced bundles AdGuard's GPL-3
[Scriptlets](https://github.com/AdguardTeam/Scriptlets) and
[ExtendedCss](https://github.com/AdguardTeam/ExtendedCss) libraries.
Filter lists are downloaded at runtime and keep their own licenses.
