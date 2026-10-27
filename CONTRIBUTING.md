# Contributing to OpenBlock

Thanks for helping. OpenBlock is small: a Swift converter, a SwiftUI app and a Safari web extension.

## Setup

```bash
brew install xcodegen
git clone git@github.com:Alhamou/OpenBlock.git
cd OpenBlock
xcodegen generate
open OpenBlock.xcodeproj
```

Signing: `project.yml` pins the author's team (`DEVELOPMENT_TEAM`). Change it to your team to run the app; Safari only loads signed extensions. For compile-only checks you can build unsigned:

```bash
xcodebuild -project OpenBlock.xcodeproj -scheme OpenBlock -configuration Debug \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="" build
```

## Tests

```bash
swift test --package-path Packages/BlockerCore   # converter
cd WebExtension && npm install && npm test        # web extension
```

If you change `WebExtension/src`, run `npm run build` and commit the regenerated files in `Extensions/Advanced/Resources`.

## Where things live

See the layout table in the [README](README.md#layout) and [docs/architecture.md](docs/architecture.md).

## Pull requests

1. Keep PRs focused; one change per PR.
2. Converter changes need a test in `Packages/BlockerCore/Tests`.
3. Content blockers must stay valid for WebKit: check with `obconvert --verify`.
4. Raw JS and `trusted-*` scriptlets are only accepted from built-in lists and user rules. Do not widen that.
5. By contributing you agree your work is released under GPL-3.0.
