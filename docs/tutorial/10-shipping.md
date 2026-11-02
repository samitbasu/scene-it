# 10 — Shipping: signing, notarization, the DMG

How a commit becomes `dist/Scene It 0.1.0.dmg` that a writer can download and open
without macOS warning them off it ([ADR 0001](../decisions/0001-distribution-developer-id.md)).
The pipeline is [`scripts/release.sh`](../../scripts/release.sh); its usage and outputs are
in the [README](../../README.md#scriptsreleasesh-build-a-distributable-app).

| Step | Tool | Rust-world analogue |
| --- | --- | --- |
| Build an optimised, universal binary plus debug info | `xcodebuild archive` | `cargo build --release` for two targets, then `lipo` |
| Sign it with our identity | `codesign`, run by Xcode | `cosign sign` / `minisign`, except the OS checks it on every launch |
| Repackage for distribution | `xcodebuild -exportArchive` | the packaging half of `cargo dist` |
| Ask Apple to scan it | `xcrun notarytool submit` | no direct analogue; closest is a Sigstore transparency-log entry |
| Attach Apple's receipt | `xcrun stapler staple` | bundling the transparency-log inclusion proof with the artifact |
| Check what a downloader's Mac will decide | `spctl -a` | none |
| Wrap it in a disk image | `diskutil image create from` | the `.dmg` installer `cargo dist` can build |
| Keep the debug info | the archive's `dSYMs/` | `-C split-debuginfo=packed` (which, on macOS, also makes a `.dSYM`) |

## Certificates and identities

A **certificate** binds a public key to a name ("Developer ID Application: Samit BASU
(8H6754RJ2W)"), and is signed by an issuing CA, which is signed by Apple's root. An
**identity** is a certificate *plus* its private key, both in the keychain. You can only
sign with an identity, so a certificate imported without its key (say, downloaded from the
developer portal on another Mac) is useless for signing. The private key was generated on
this Mac when Xcode → Settings → Accounts → Manage Certificates → + created the certificate,
so it exists nowhere else. Export it (`.p12`) from Keychain Access if you want a backup.

`security` lists the identities that can sign code. `-v` keeps only *valid* ones, meaning
a chain to a trusted root can be built and nothing has expired or been revoked:

```
$ security find-identity -p codesigning
Policy: Code Signing
  Matching identities
  1) 3442099175035061EFF6A571030F106C0A04BADD "Apple Development: basu.samit@gmail.com (8ZAS68XBDQ)"
  2) 0F9F7A860F9AD030631A6F2ED4AADF9F8ABD9757 "Developer ID Application: Samit BASU (8H6754RJ2W)"
  3) 485D91AB963F5676ADBB92F4B7FCB1E7F95F79A1 "Apple Development: Samit BASU (8ZAS68XBDQ)"
     3 identities found

  Valid identities only
  1) 0F9F7A860F9AD030631A6F2ED4AADF9F8ABD9757 "Developer ID Application: Samit BASU (8H6754RJ2W)"
     1 valid identities found
```

### Why the Apple Development certificates showed as invalid

Each certificate names its issuer, and the chain is only as good as the certificates you can
find for each link. The two *Apple Development* certificates were issued by
**Apple Worldwide Developer Relations Certification Authority, OU=G3**. The keychains held
only the original WWDR CA from 2013, a different certificate with the same common name that
expired in February 2023:

```
$ openssl x509 -noout -subject -dates < wwdr.pem      # the only WWDR CA in the keychains
subject=C=US, O=Apple Inc., OU=Apple Worldwide Developer Relations, CN=Apple Worldwide Developer Relations Certification Authority
notBefore=Feb  7 21:48:47 2013 GMT
notAfter=Feb  7 21:48:47 2023 GMT
```

With no G3 intermediate there was no path from the leaf to *Apple Root CA*, so
`find-identity -v` left them out. Apple publishes the intermediates at
[apple.com/certificateauthority](https://www.apple.com/certificateauthority/), and each
certificate also names where its issuer can be downloaded (`openssl x509 -noout -ext
authorityInfoAccess` prints `CA Issuers - URI:http://certs.apple.com/wwdrg3.der`). Once
the G3 (and G6) intermediates were in the login keychain, the same command reported
`3 valid identities found`. It's the
same failure as a TLS server that sends its leaf certificate without the intermediate: the
leaf is fine, but the verifier can't reach the root.

The *Developer ID* certificate chains through a different intermediate, **Developer ID
Certification Authority**, which was present, so it was valid all along:

```
$ security verify-cert -c devid.pem -p codeSign -L -v
 0: Developer ID Application: Samit BASU (8H6754RJ2W)
    Not After : Feb 1, 2027 22:12
 1: Developer ID Certification Authority
    Not After : Feb 1, 2027 22:12
 2: Apple Root CA
    Not After : Feb 9, 2035 21:40
```

Note the date: a certificate can't outlive its issuer, and this one was issued by the
original Developer ID CA, which expires on **1 February 2027**. Releases made after that
need a new Developer ID certificate. Builds already shipped keep working, because of the
secure timestamp (below).

### Which certificate is for what

| Certificate | Signs | Runs on |
| --- | --- | --- |
| Apple Development | builds you run and debug yourself | Macs registered to the team |
| **Developer ID Application** | apps distributed outside the Mac App Store | any Mac, once notarized |
| Developer ID Installer | `.pkg` installers (we ship a DMG, so not needed) | any Mac |
| Apple Distribution | uploads to the App Store, which Apple re-signs | App Store customers |

The App Store route would mean the App Sandbox and App Review. ADR 0001 explains why we chose
Developer ID instead.

## The project's signing settings

Signing is configured per build configuration at the project level in
[`project.pbxproj`](../../SceneIt.xcodeproj/project.pbxproj) (see [chapter 01](01-project-anatomy.md)
for how settings layer). Debug:

```
CODE_SIGN_IDENTITY = "-";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = 8H6754RJ2W;
```

Release:

```
CODE_SIGN_IDENTITY = "Developer ID Application";
CODE_SIGN_STYLE = Manual;
DEVELOPMENT_TEAM = 8H6754RJ2W;
OTHER_CODE_SIGN_FLAGS = "--timestamp";
```

and on the app target, for both configurations, `ENABLE_HARDENED_RUNTIME = YES`.

- `"-"` means **ad hoc**: a signature with no certificate. Debug stays ad hoc so that
  `scripts/check.sh` and the hosted tests run on any Mac, with no certificate at all.
  Hosting the tests works because Xcode turns the hardened runtime off for ad-hoc builds
  (`note: Disabling hardened runtime with ad-hoc codesigning.`), so its *library validation*,
  which only lets a process load code signed by Apple or by its own team, never applies to
  the test bundle the app loads.
- `"Developer ID Application"` is a prefix. Xcode picks the identity whose name starts with
  it and whose team is `DEVELOPMENT_TEAM`. `Manual` means Xcode doesn't create or download
  certificates or profiles on its own (a Developer ID app without special entitlements needs
  no provisioning profile).

The archive log shows what Xcode then runs:

```
/usr/bin/codesign --force --sign 0F9F7A860F9AD030631A6F2ED4AADF9F8ABD9757 --timestamp -o runtime --entitlements …/Scene It.app.xcent …
```

`-o runtime` is the hardened runtime, and the SHA-1 is the identity from `find-identity`.

## Reading a signature

```
$ codesign -dvv "build/release/0.1.0-22-unnotarized/export/Scene It.app"
Identifier=com.samitbasu.SceneIt
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=1633 flags=0x10000(runtime) hashes=40+7 location=embedded
Signature size=8971
Authority=Developer ID Application: Samit BASU (8H6754RJ2W)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Nov 1, 2026 at 11:09:52 PM
Info.plist entries=23
TeamIdentifier=8H6754RJ2W
Runtime Version=27.2.0
Sealed Resources version=2 rules=13 files=0
```

- The **CodeDirectory** is a table of hashes: one per 4 KiB page of the executable, plus
  hashes of `Info.plist` and of `_CodeSignature/CodeResources`, which in turn lists a hash
  for every other file in the bundle. The signature signs the CodeDirectory. Changing any
  byte of the bundle breaks it, which `codesign --verify --deep --strict` reports.
- **Authority** lines are the certificate chain, leaf first.
- `flags=0x10000(runtime)` is the hardened runtime. A Debug build shows `flags=0x2(adhoc)`
  and no Authority lines.
- **TeamIdentifier** is what Gatekeeper, library validation and the keychain use to decide
  that two pieces of code come from the same developer.

The *designated requirement* is the rule a future version must satisfy to count as "the
same app" (to keep keychain items and privacy permissions, for instance). For Developer ID it
pins the bundle ID and our team, not a particular certificate, so a renewed certificate
still satisfies it:

```
$ codesign -d -r- "…/Scene It.app"
designated => anchor apple generic and identifier "com.samitbasu.SceneIt" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "8H6754RJ2W")
```

## The hardened runtime and entitlements

The hardened runtime is opt-out security. With it on, the kernel and `dyld` refuse
`DYLD_INSERT_LIBRARIES`, debugger attachment, unsigned executable memory (JIT) and
libraries signed by another team. Each refusal can be lifted by an **entitlement**, a
key/value claim inside the signature. Our Release app has none:

```
$ codesign -d --entitlements - "…/export/Scene It.app"
[Dict]
```

Xcode gives Debug builds `com.apple.security.get-task-allow` (so the debugger can attach),
plus some exceptions the test runner needs. Release builds never get it, and notarization
rejects any app that has it. We don't need an entitlements file in `Config/`: we use no
sandbox, no JIT and no plug-ins.

## Secure timestamps

A signature made with an expired certificate is invalid. Then why do apps keep working after
their developer's certificate expires? Because of `--timestamp`: `codesign` sends the
CodeDirectory hash to Apple's timestamp server, which signs "this hash existed at this time".
That countersignature goes in the signature (the `Timestamp=` line above), and verifiers check
the certificate's validity *at that time* rather than now. Notarization requires it, so
Release asks for it explicitly with `OTHER_CODE_SIGN_FLAGS = "--timestamp"`, and
`release.sh` refuses to continue without a `Timestamp=` line. Debug's ad-hoc signatures
can't carry one: there is no certificate whose validity a timestamp could vouch for.

## Notarization and stapling

**Notarization** is Apple scanning the exact bytes we built for malware and for signing
mistakes (no hardened runtime, no timestamp, `get-task-allow`). `notarytool` uploads a zip
or a DMG, and Apple records the result against the hashes of every signed file inside. Gatekeeper
on any Mac can then look that record up online.

**Stapling** downloads that record (the *ticket*) and attaches it to the app or DMG, so
the check also works offline. A stapled ticket lives in `Contents/CodeResources` for an app
and in the image for a DMG. It is not part of the signature, so stapling doesn't invalidate it.
Before notarization:

```
$ xcrun stapler validate "Scene It.app"
Processing: …/Scene It.app
Scene It.app does not have a ticket stapled to it.
```

`notarytool` authenticates with an app-specific password stored in the keychain under a
**profile name** (`scene-it-notary`). Scripts refer to the profile, so the password never
appears in the repository, in a command line or in `ps`. Without the profile, `release.sh`
stops before building:

```
$ scripts/release.sh
release.sh: notarytool can't use the keychain profile "scene-it-notary":
Error: No Keychain password item found for profile: scene-it-notary

Run 'notarytool store-credentials' to create another credential profile.
Create the profile once (it prompts for an app-specific password from account.apple.com), then re-run:
    xcrun notarytool store-credentials scene-it-notary --apple-id <your Apple ID email> --team-id 8H6754RJ2W
Or build a tester copy without notarization: scripts/release.sh --unnotarized
```

If Apple rejects a submission, `release.sh` fetches the JSON log (`xcrun notarytool log <id>`),
which names each offending file and the reason.

## Gatekeeper and quarantine

When a browser, Mail or AirDrop saves a file, it adds the extended attribute
`com.apple.quarantine`. (It's like Windows' Mark-of-the-Web.) The first launch of a
quarantined app goes through **Gatekeeper**, which checks the signature and the notarization
ticket. Files you build yourself are never quarantined, which is why your own builds open
without complaint. To see what a downloader gets, ask `spctl` (Gatekeeper's command-line
front end). It assesses the file whether or not it carries the quarantine attribute, so
there's no need to add one; double-clicking, by contrast, only consults Gatekeeper for a
quarantined file (`xattr -w com.apple.quarantine "0083;6725a000;Safari;" <file>` adds one
by hand).

```
$ spctl -a -vvv -t exec "Scene It.app"
Scene It.app: rejected
source=Unnotarized Developer ID
origin=Developer ID Application: Samit BASU (8H6754RJ2W)
```

That's an `--unnotarized` build: correctly signed, but Gatekeeper wants the notarization too.
A notarized app reports `accepted` and `source=Notarized Developer ID`, which is what
`release.sh` requires before it continues. For a DMG the type is `install`
(`spctl -a -vvv -t install`). The signed but unnotarized DMG gets the same verdict as the app:

```
$ spctl -a -vvv -t install "Scene It 0.1.0.dmg"
Scene It 0.1.0.dmg: rejected
source=Unnotarized Developer ID
origin=Developer ID Application: Samit BASU (8H6754RJ2W)
```

An app that Gatekeeper rejects can still be allowed by its user, once, via System Settings →
Privacy & Security → **Open Anyway**. Since macOS 15, Control-click → Open no longer
skips the check. The `--unnotarized` zip's `README.txt` walks a tester through it.
Nothing here involves the user's Apple ID: running a Mac app never requires one.

## The DMG

A DMG is a disk image: a file containing a file system. Ours holds the stapled app and a
symbolic link to `/Applications`, so the window that opens invites a drag. It's made with
`diskutil image create from --format UDZO` (zlib-compressed, read-only), which puts an APFS
volume inside the image, so it opens on any Mac we support (macOS 26 and later). `hdiutil` used to
do this; its man page on macOS 27 marks the verb deprecated in favour of `diskutil image`.
The DMG gets its own Developer ID signature, notarization and staple, so the first thing
the downloader opens is trusted, and the app inside is checked again when it launches.

## dSYMs and symbolication

Release builds are optimised and their symbol tables are stripped: the shipped executable
has 826 symbols for arm64, the debug info 5982. The DWARF goes into a separate **dSYM**
bundle (`DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"`), much like
`-C split-debuginfo=packed` in Rust, or `objcopy --only-keep-debug` on Linux. A binary and its
dSYM are matched by **UUID**, one per architecture:

```
$ dwarfdump --uuid "build/release/0.1.0-22-unnotarized/Scene It.xcarchive/dSYMs/Scene It.app.dSYM"
UUID: BC6B9049-C8D8-32AC-8A32-6F345C1B0398 (x86_64) …/Scene It.app.dSYM/Contents/Resources/DWARF/Scene It
UUID: AB5CF756-505B-3C8D-911C-7A4CC3CC4D6A (arm64) …/Scene It.app.dSYM/Contents/Resources/DWARF/Scene It
$ dwarfdump --uuid "Scene It.app/Contents/MacOS/Scene It"
UUID: BC6B9049-C8D8-32AC-8A32-6F345C1B0398 (x86_64) Scene It.app/Contents/MacOS/Scene It
UUID: AB5CF756-505B-3C8D-911C-7A4CC3CC4D6A (arm64) Scene It.app/Contents/MacOS/Scene It
```

The linker derives the UUID from the binary's contents, and those contents include the
build's paths (in debug-info references) as well as everything the code, compiler and SDK
contribute. Archiving one commit twice from the same checkout gave the same UUIDs; archiving
the same commit from a different directory gave different ones (`F8F295AE…`/`354CD52E…`
versus `A94CC72E…`/`C8FE06C3…`). In practice, **rebuilding a commit later produces different
UUIDs**, so a crash report can only be symbolicated with the dSYM from *that* build, and a
lost dSYM can't be recovered. That's why `release.sh` keeps every archive twice:

- in `build/release/<version>-<build>/`, next to the exported app and logs, and never
  overwrites it;
- as a copy in `~/Library/Developer/Xcode/Archives/<yyyy-MM-dd>/Scene It <version>-<build>.xcarchive`,
  outside the repository, where Xcode's Organizer lists it and Spotlight indexes the dSYM
  by UUID. It refuses to overwrite an archive there with the same name, too.

A crash report (`.ips`) gives, for each frame, the image's load address and an offset;
`atos` (≈ `addr2line`) turns an address into a function and line. Here is the same address
looked up with the dSYM and with the shipped binary, using a made-up load address of
`0x104a20000`:

```
$ cd build/release/0.1.0-22-unnotarized
$ atos -arch arm64 -o "Scene It.xcarchive/dSYMs/Scene It.app.dSYM/Contents/Resources/DWARF/Scene It" \
       -l 0x104a20000 0x104a738d4
EncodingFailure.description.getter (in Scene It) (PersistenceErrors.swift:14)
$ atos -arch arm64 -o "export/Scene It.app/Contents/MacOS/Scene It" -l 0x104a20000 0x104a738d4
0x00000001000538d4 (in Scene It) + 12
```

Console.app and Xcode symbolicate automatically when Spotlight can find a dSYM with the
right UUID. For the copy in Xcode's archives folder it does:

```
$ mdfind "com_apple_xcode_dsym_uuids == 354CD52E-A24B-3926-A79B-9B6C9AD67715"
/Users/samitbasu/Library/Developer/Xcode/Archives/2026-11-01/Scene It 0.1.0-26-unnotarized.xcarchive
/Users/samitbasu/Library/Developer/Xcode/Archives/2026-11-01/Scene It 0.1.0-26-unnotarized.xcarchive/dSYMs/Scene It.app.dSYM
```

The same query found nothing under a checkout's `build/release/`, so to use that copy, pass
its path to `atos`.
[Chapter 11](11-crash-reporting.md#symbolication) shows where the addresses come from in a report.

## `release.sh`, start to finish

The script refuses to start unless the tree is clean, `HEAD` is on `origin/main` (after a
fetch) in a full, non-shallow clone, the identity is present, the notary profile works
(default mode), nothing from an earlier build of the same commit would be overwritten, and
`scripts/check.sh` passes. It works in `build/release/<version>-<build>.partial/` (deleting
a leftover one from an interrupted run first) and renames it only once everything has
passed. Then:

1. `xcodebuild clean archive` with `CURRENT_PROJECT_VERSION` set to `git rev-list --count HEAD`.
   That becomes `CFBundleVersion`. The commit count only identifies a commit on a single line
   of history, which is why the script releases nothing but commits already on `origin/main`:
   there, each count names exactly one commit, and a later release always has a higher
   count. (A branch commit can share its count with a different `main` commit.) A shallow
   clone would count only the commits it fetched.
2. `xcodebuild -exportArchive` with [`Config/ExportOptions.plist`](../../Config/ExportOptions.plist):

   ```xml
   <key>method</key>
   <string>developer-id</string>
   <key>signingStyle</key>
   <string>manual</string>
   <key>teamID</key>
   <string>8H6754RJ2W</string>
   ```

3. Checks the signature: `--verify --deep --strict`, our team, `runtime`, a timestamp.
4. Zips the app with `ditto -c -k --keepParent` (unlike `zip`, `ditto` keeps the extended
   attributes and symlinks a bundle relies on), notarizes it, staples the app and checks it
   with `spctl`. `stapler` is retried up to three times, because the ticket can take a
   moment to become available after `notarytool` reports *Accepted*.
5. Builds, signs, notarizes and staples the DMG inside the release directory, and checks it
   with `spctl -t install`.
6. Copies the archive into `~/Library/Developer/Xcode/Archives/`, moves the DMG into
   `dist/`, and renames the `.partial` directory. Nothing reaches `dist/` unless every check
   has passed.

With `--unnotarized` it stops after step 3, zips the app with a `README.txt` for testers,
and does step 6. Its output (here run from a scratch clone whose `origin/main` contained
the commit, since this branch isn't merged yet):

```
$ scripts/release.sh --unnotarized
/Users/samitbasu/…/clone/dist/Scene It 0.1.0-unnotarized.zip
/Users/samitbasu/…/clone/build/release/0.1.0-26-unnotarized/Scene It.xcarchive/dSYMs/Scene It.app.dSYM
/Users/samitbasu/Library/Developer/Xcode/Archives/2026-11-01/Scene It 0.1.0-26-unnotarized.xcarchive
```

The notarized path hasn't run yet: it needs the `scene-it-notary` profile. When it has, the
expected `spctl` verdicts are the `accepted` / `source=Notarized Developer ID` lines above.
