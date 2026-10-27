# Security

OpenBlock injects scripts and CSS into web pages through Safari, so bugs here matter.

## Reporting

For anything that could put users at risk before a fix ships (for example a way for a filter list or a web page to run code it should not), use GitHub's **private vulnerability reporting** on this repository. Everything else can be a normal issue.

## What OpenBlock does not do

- No telemetry, analytics or crash reporting.
- The only network traffic is downloading the filter lists you enabled, from the URLs shown in the app.
- It does not read your browsing history.

## Trust model

Scriptlets from filter lists run in the page world. Raw JavaScript and `trusted-*` scriptlets are accepted only from the built-in lists and from your own rules; CSS injections containing `url()` or `@import` are dropped. Lists you add yourself are treated as untrusted.
