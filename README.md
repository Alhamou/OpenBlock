<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="OpenBlock icon">
</p>

<h1 align="center">OpenBlock</h1>

<p align="center">An open-source ad blocker for Safari on macOS. Real filter lists, native content blockers, no tracking.</p>

<p align="center">
  <a href="https://github.com/Alhamou/OpenBlock/releases/latest">Download</a> ·
  <a href="docs/architecture.md">Architecture</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="https://github.com/Alhamou/OpenBlock/actions/workflows/ci.yml"><img src="https://github.com/Alhamou/OpenBlock/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-lightgrey" alt="macOS 15+">
</p>

---

OpenBlock is built the same way as AdGuard for Safari: **filter lists → converter → Safari content blockers**.
The app downloads lists, converts them to Safari's native rule format and hands them to Safari, which
compiles them into its own engine. Nothing sits between you and the web, and nothing is sent anywhere.

- **4 Safari content blockers**: Ads, Privacy, Annoyances, Custom. Each has its own 150k-rule budget.
- **Real filter lists**: AdGuard Base/Tracking/Social/Cookie/Popups (Safari builds), EasyList, EasyPrivacy, regional lists, or any URL you add (AdBlock syntax or hosts files).
- **User rules and an allowlist**, in AdBlock syntax.
- **OpenBlock Advanced**, a Safari Web Extension for the rules content blockers can't express:
  scriptlets (`#%#//scriptlet(...)`, uBO `##+js(...)`), CSS injection (`#$#`), extended CSS
  (`#?#`, `:has-text()`, `:remove()` …) and rules on wildcard-TLD domains (`example.*`).
  Examples are YouTube ads and anti-adblock walls. Its toolbar button shows the current site's
  status and pauses the advanced rules per site.
- **Lives in the menu bar**: status, *Update Filters Now*, *Pause Blocking*, *Launch at Login*. The Dock
  icon only shows while the OpenBlock window is open (Settings → "Keep OpenBlock in the menu bar only").
- **Auto-update** of filter lists every 24 hours while OpenBlock is running (in the menu bar is enough).
- **Open source**: GPL-3.0, with a converter you can run from the command line and verify against WebKit's own compiler.

OpenBlock blocks only inside Safari. Safari compiles the rules into its own engine; other browsers and
apps never see them. DNS-based blocking for every app is the next planned feature (see [Roadmap](#roadmap)).

## Install

Requires macOS 15 Sequoia or later.

1. Download `OpenBlock-<version>.dmg` from the [latest release](https://github.com/Alhamou/OpenBlock/releases/latest), open it and drag OpenBlock to Applications.
2. On first launch macOS will say the app is from an unidentified developer. The build is signed with an Apple Development certificate rather than a Developer ID, and it is not notarized. To open it anyway: **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to OpenBlock. Or from a terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/OpenBlock.app
   ```
3. Open OpenBlock, pick your filter lists, and wait for the first conversion to finish.
4. In **Safari → Settings → Extensions**:
   1. enable the four **OpenBlock** content blockers;
   2. enable **OpenBlock Advanced**, select it in the list and allow it on every website
      in the pane on the right. An **OpenBlock** button then appears in Safari's toolbar.

Keep one copy of the app on disk: Safari gets confused when two builds register the same extensions.

## Using it

- **Filter lists**: toggle lists on or off. Changes show an *Apply Changes* button; only lists that are new are downloaded.
- **User rules**: your own rules in AdBlock syntax, applied by the Custom blocker and OpenBlock Advanced.
- **Allowlist**: sites where blocking is off.
- **Menu bar**: *Update Filters Now*, *Pause Blocking*, *Launch at Login*.
- **Toolbar popup**: the OpenBlock button in Safari's toolbar shows the current site, whether OpenBlock
  Advanced is active there, and a *Pause on this site* switch that turns the advanced rules off for that
  site (and its subdomains) until you switch it back on.
- OpenBlock reloads each blocker as soon as you come back to the app.

## How it works

```
OpenBlock.app (SwiftUI)
 ├─ FilterManager: download → BlockerCore.convert → write JSON → reload blockers
 └─ PlugIns/
     ├─ OpenBlock Ads / Privacy / Annoyances / Custom   Safari content blockers (read JSON from an App Group)
     └─ OpenBlock Advanced                              Safari Web Extension (scriptlets, extended CSS)
```

The full design, including Safari's constraints and the converter's rule order, is in [docs/architecture.md](docs/architecture.md).

## Build from source

Requirements: macOS 15+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone git@github.com:Alhamou/OpenBlock.git && cd OpenBlock
xcodegen generate
open OpenBlock.xcodeproj   # run the "OpenBlock" scheme
```

or from the terminal:

```bash
xcodebuild -project OpenBlock.xcodeproj -scheme OpenBlock -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/OpenBlock.app
```

`project.yml` pins the author's signing team. To use your own, change `DEVELOPMENT_TEAM` there; the App Group ID is derived from it.
Safari only loads signed extensions, so unsigned builds do not block anything.

Development builds: every rebuild changes the extension's signature, and Safari then turns
OpenBlock Advanced off and drops its website permission. Re-enable it after each build.

Self-test: `python3 -m http.server 8765 --directory TestPages`, add `TestPages/rules.txt` to
User Rules, and open http://localhost:8765/advanced.html in Safari.

### Web extension

The web extension's JavaScript is built from `WebExtension/` into `Extensions/Advanced/Resources`
(the built files are committed, so Xcode doesn't need Node):

```bash
cd WebExtension
npm install
npm test
npm run build
```

### Converter CLI

```bash
cd Packages/BlockerCore
swift test
swift run -c release obconvert easylist.txt --out rules.json --verify
```

`--verify` compiles the output with `WKContentRuleListStore`, the same compiler Safari uses.

### Release

```bash
scripts/make-dmg.sh        # Release build → build/OpenBlock-<version>.dmg
```

## Layout

| Path | What |
|---|---|
| `Packages/BlockerCore` | Rule parser + Safari converter (pure Swift, unit-tested) and the `obconvert` CLI |
| `App/` | SwiftUI host app: downloads, converts, writes JSON, reloads blockers; menu bar item and settings |
| `Extensions/ContentBlocker` | One request handler compiled into the four blocker extensions |
| `Extensions/Advanced` | OpenBlock Advanced web extension: native handler + built JS bundle |
| `WebExtension/` | Source of the web extension (background worker, content script, toolbar popup, rule lookup, tests) |
| `Shared/` | App Group paths used by the app and the extensions |
| `TestPages/` | Local pages and rules for self-testing |
| `scripts/` | `make-dmg.sh`, icon generator |
| `docs/` | Architecture |

## Roadmap

- **Next**: DNS-based blocking for every app on the Mac, not just Safari.
- `$redirect` / `$removeparam` through `declarativeNetRequest`.
- Element picker, incremental list updates.
- Developer ID signing and notarization.

Ideas and bug reports are welcome in [Issues](https://github.com/Alhamou/OpenBlock/issues).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

GPL-3.0 (see [LICENSE](LICENSE)), because OpenBlock Advanced bundles AdGuard's GPL-3
[Scriptlets](https://github.com/AdguardTeam/Scriptlets) and
[ExtendedCss](https://github.com/AdguardTeam/ExtendedCss) libraries.
Filter lists are downloaded at runtime and keep their own licenses.
OpenBlock is not affiliated with AdGuard.
