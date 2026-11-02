# 0001 — Distribute with Developer ID + notarization

**Status:** Accepted (2026-11-01)

## Decision
Join the Apple Developer Program. Ship the app outside the Mac App Store, signed
with a *Developer ID Application* certificate, with the **hardened runtime**
enabled, and **notarized** by Apple (`xcrun notarytool`, then `xcrun stapler`).
The App Sandbox is not enabled.

## Alternatives
- **Free Apple ID, ad-hoc signing:** Gatekeeper warns or blocks on other Macs, which writers will read as "untrustworthy".
- **Mac App Store:** requires the sandbox (security-scoped bookmarks for every book folder) and App Review. More friction for the archive and backup design.

## Consequences
- The hardened runtime is on from day one, so we never discover late that something we depend on needs an entitlement.
- Releases go through `scripts/release.sh` (tracked as an issue): archive → export → notarize → staple → DMG.
- Crash reports don't flow to App Store Connect, which is why [0006](0006-crash-reporting.md) exists.

## Learning notes (for a Rust programmer)
- **Code signing** is like signing a release artifact, but the OS enforces it at launch. *Gatekeeper* checks the signature and, for downloaded apps, the **notarization ticket**: Apple's record that it scanned this exact binary.
- **Stapling** embeds that ticket in the app, so the check works offline.
- The **hardened runtime** is a set of opt-out security restrictions, such as no unsigned executable memory and no DYLD injection. Notarization requires it.
- An **entitlement** is a signed key/value claim that grants a capability (sandbox, JIT, and so on). Think of it as capabilities declared in the binary rather than requested at runtime.
