# TokenScope Packaging

This directory contains a simple macOS packaging script for the SwiftPM-based TokenScope app.

## Build app + DMG

```bash
packaging/build_dmg.sh
```

Outputs:

```text
dist/TokenScope.app
dist/TokenScope-1.0.0.dmg
```

The generated app is ad-hoc signed (`codesign --sign -`) so it can launch locally, but it is **not notarized**. On another Mac, Gatekeeper may show an unidentified-developer warning. For public distribution, use an Apple Developer ID certificate and notarization.

## Install

Open the DMG and drag `TokenScope.app` into `/Applications`.
