# RimeAI iOS internal TestFlight handoff

Snapshot: 2026-08-01, Asia/Shanghai

Conclusion: **已进入内部 TestFlight，等待真机验收**

This report covers the independent iOS feasibility track only. It does not
expand the macOS-first product scope, declare semantic AI support on iOS, submit
an App Store review, or change storefront availability.

## Current state

- App Store Connect app: `RimeAI 本地输入法`
- Apple ID: `6796064035`
- SKU: `RIMEAI-IOS-001`
- Team: `S3T42U45P8`
- TestFlight build: `0.1.0 (2)`
- Build processing state: `VALID`
- Internal beta state: `IN_BETA_TESTING`
- Internal group: `friends`
- Group relationship: build 2 is present; the group has access to all builds
- Tester state: one internal tester, `INSTALLED`
- Physical-device state: TestFlight build `0.1.0 (1)` remains installed on the
  paired iPhone SE (3rd generation). Its keyboard was exercised on iOS 27 and
  reproduced clipped right-edge letters plus an overlapped, unusable function
  row. The corrected build `0.1.0 (2)` is available to the internal group but
  has not yet been installed on the device.
- Git state: branch `main`; repository contents are untracked; nothing was
  staged, committed, or pushed

## Configuration alignment

| Item | Current/target value | Evidence | State |
|---|---|---|---|
| Canonical project source | `ios/project.yml` | XcodeGen regeneration | aligned |
| Host bundle ID | `fun.wwcn.rimeai.app` | Release settings, signed archive, ASC | aligned |
| Keyboard bundle ID | `fun.wwcn.rimeai.app.keyboard` | Release settings, signed archive, Developer profile | aligned |
| Team | `S3T42U45P8` | Release settings and signed entitlements | aligned |
| Display name | `RimeAI 本地输入法` | archived `Info.plist`, ASC zh-Hans localization | aligned |
| URL scheme | none | both source `Info.plist` files | intentionally absent |
| Version/build | `0.1.0 (2)` | archived host and extension, TestFlight build | aligned |
| Minimum iOS | 17.0 | Build Settings, Mach-O load command, ASC build | aligned |
| Devices | iPhone and iPad | `TARGETED_DEVICE_FAMILY=1,2`, archived plist | aligned; iPad real device pending |
| Host orientation | portrait and both landscapes | source/archived plist | aligned |
| iPad orientation | all four orientations | source/archived plist | aligned |
| Production API | none | source scan; no network client or endpoint | intentionally absent |
| Keyboard open access | `false` | source and archived extension plist | aligned |
| ATS exception | none | source and archived plist | aligned |
| Permissions | no camera/photo/microphone/location declarations | source scan and archived plist | aligned |
| Privacy manifest, host | no collection/tracking; UserDefaults `CA92.1` | archived manifest and linked symbol scan | aligned |
| Privacy manifest, keyboard | no collection/tracking; file metadata `C617.1` | archived manifest and linked `fstat` scan | aligned |
| Export encryption | `ITSAppUsesNonExemptEncryption=false` | no cryptographic feature or crypto dependency in the iOS runtime | aligned |
| Signing profiles | `RimeAI iOS App App Store`; `RimeAI iOS Keyboard App Store` | archived embedded profiles | aligned |
| Signed host entitlement | app identifier, Team, beta reports; `get-task-allow=false` | `codesign -d --entitlements :-` | aligned |
| Signed keyboard entitlement | extension identifier, Team, beta reports; `get-task-allow=false` | `codesign -d --entitlements :-` | aligned |
| App icon | branded 1024×1024 RimeAI icon | asset source and successful App Store validation | aligned |
| Third-party notices | 10 bundled license files | final archive and IPA listing | engineering inventory complete |
| Formal App Store version | ASC `1.0`, `PREPARE_FOR_SUBMISSION` | live ASC API | not part of this internal build; align before store submission |
| Storefront availability | no availability resource exists | live ASC API returned 404 for app availability | unchanged |
| App privacy URL | null | live ASC API | required before formal App Store submission |

## Local implementation completed

- Added a controlled iOS 17 arm64 device/Simulator
  `RimeAINative.xcframework`, with source revisions in
  `Native/artifact-lock.json`.
- Added precompiled Simplified Chinese Rime data for extension startup.
- Added a C bridge entry that starts the prebuilt runtime without extension
  first-launch schema maintenance.
- Added the serial background Rime engine, composition state, candidate strip,
  candidate commit, delete, space, return, and next-keyboard behavior.
- Added native candidate and real system-keyboard UI tests.
- Replaced fragile horizontal stack-view sizing with pixel-aligned weighted
  key rows, retaining equal letter widths and a `1:1:2.5:1` function-row ratio.
- Added iPhone SE layout coverage for containment, minimum key widths,
  non-overlap, title/image clipping, key operation, and `nihao` candidate
  commit.
- Added applicable required-reason API declarations after inspecting the final
  linked host and extension binaries.
- Bundled exact third-party license texts and updated the dependency inventory.
- Regenerated `RimeAIiOS.xcodeproj` from `project.yml`.
- Updated host UI and documentation to state that native Rime works while the
  semantic ranking model and physical-device acceptance remain incomplete.

## External resources

No additional Apple or EAS resource creation is waiting for confirmation.
This is a native Xcode project; EAS does not apply.

Existing and verified:

- Explicit host and extension identifiers
- App Store Connect app record
- Distribution certificate
- Two App Store provisioning profiles
- Internal group `friends`
- Valid internal TestFlight builds `0.1.0 (1)` and `0.1.0 (2)`

Intentionally not created:

- Development provisioning profiles for local device installation
- App Group, Sign in with Apple, Push, Associated Domains, IAP, iCloud,
  Keychain Sharing, or background capabilities

## Verification record

| Command/check | Result |
|---|---|
| `xcodegen generate --spec ios/project.yml --project ios` | succeeded |
| XcodeBuildMCP iPhone SE simulator integration + UI suite | 3 passed, 0 failed |
| Native test: `nihao` candidate and commit | passed; included `你好` |
| System keyboard UI test: enable/switch/layout/type/select | passed; all letter/function frames were contained and non-overlapping; text field became `你好` |
| SE visual attachment | `/Users/wangwei/Desktop/RimeAI iPhone SE Keyboard Layout - Build 2 Candidate.png`; all right-edge and function-row keys render separately |
| `swift test` | 21 passed |
| `uv run --isolated --with pytest python -m pytest -q` | 61 passed |
| `plutil -lint` on both privacy manifests | both OK |
| Release Build Settings | correct Team, bundle IDs, 0.1.0 (2), iOS 17, manual App Store signing |
| `xcodebuild ... clean archive` | build 2 archive succeeded on the final source state |
| `codesign --verify --deep --strict` | valid and satisfies designated requirement |
| Signed entitlement inspection | exact identifiers/Team; beta reports on; debug entitlement off |
| `xcodebuild -exportArchive` | succeeded |
| Final build 2 IPA | 16 MB; SHA-256 `67198ce3ba1b3e28cf362e2145c9b9a21b16b9e7e48904b8e2067f51818c208c` |
| `altool --validate-app` | succeeded with exit code 0 |
| `altool --upload-package --wait` | build 2 upload succeeded; delivery `07a5dd9c-f389-4b47-8f38-6b1045ba8fcd` |
| App Store Connect build poll | build 2 `VALID`, iOS 17.0, non-exempt encryption false |
| Internal group poll | build 2 present; internal state `IN_BETA_TESTING` |
| Internal tester poll (2026-08-01) | one tester; state `INSTALLED` |
| `devicectl device info apps` after build 2 processing | paired iPhone SE still has RimeAI `0.1.0 (1)`; build 2 device installation is pending |
| `devicectl device process launch` | host bundle `fun.wwcn.rimeai.app` launched successfully |
| `devicectl device info processes` | live host executable observed as PID 14023; TestFlight service extension also present |
| Host process lifecycle | PID 14023 accepted a normal terminate signal, disappeared, then `--no-activate` relaunch succeeded as PID 14063 |
| `devicectl device process sendMemoryWarning` | did not complete (`NSPOSIXErrorDomain` 2); the process remained alive, so memory-pressure acceptance is not proven |
| Xcode physical-device screenshot | actual RimeAI host UI rendered on the paired iPhone |
| Build 1 keyboard screenshot | keyboard exercised on iOS 27; captured the clipped right edge and overlapped function row that build 2 addresses |
| iPhone Settings keyboard list (2026-08-01) | `RimeAI` is present in the enabled keyboard list; its row exposes no Full Access settings because the extension does not request open access |
| Keyboard-settings screenshot | `/Users/wangwei/Desktop/Screenshot 2026-08-01 at 13.46.26.png` |

One incorrect Python invocation (`uv run --isolated pytest -q`) used a
system pytest without installing the project and failed during collection.
The corrected isolated command above passed all 61 tests.

For build 1, the first legacy `altool --upload-app` call did not print a
delivery ID. A subsequent current `--upload-package --wait` attempt was rejected
as a duplicate, and the live builds API then confirmed that original upload as
`VALID`. Build 2 was later uploaded once with the delivery recorded above.

## Remaining blockers

### Code blockers

- No known local code blocker remains for build 2. The iOS 27-specific layout
  fix is not accepted until the corrected TestFlight binary passes on the same
  physical device that reproduced build 1.
- The semantic RimeAI ranking model is not integrated on iOS, so this build
  must not be described as the completed RimeAI iOS product.
- Physical-device memory pressure and lifecycle behavior may still reveal code
  changes that require a later build.

### Account blockers

- None for internal TestFlight installation; the internal tester state is now
  `INSTALLED`.
- App privacy URL and formal App Store version metadata are incomplete for a
  future public App Store submission; they do not block this internal build.

### External-service blockers

- None for internal TestFlight.
- Public redistribution/legal review for LGPL Rime data and corresponding
  source/material obligations remains outside this internal engineering gate.

### Physical-device acceptance pending

Completed on the paired iPhone SE (3rd generation) with build 1: TestFlight
acceptance, build installation, host-app launch, RimeAI keyboard enablement,
and the open-access-off configuration check. Build 1 then failed the keyboard
layout check on iOS 27; the reporter screenshot is
`/Users/wangwei/Downloads/Screenshot 2026-08-01 at 17.47.45.png`.

1. Install TestFlight build `0.1.0 (2)` and confirm the installed build number.
2. Repeat the same small-screen layout check: right-edge `p/l/m`, all titles,
   and globe/delete/space/return must be visible, separate, and operable.
3. Type `nihao`, select `你好`, and repeat in a representative system or
   third-party text field.
4. Exercise keyboard switching, host relaunch, extension termination/restart,
   memory pressure, and iPhone/iPad orientation.
5. Confirm no network traffic and no raw-input logging on the physical device.

The host process has passed a basic graceful terminate/relaunch check. The
keyboard extension lifecycle and memory-pressure checks remain pending; a
failed `devicectl` memory-warning attempt is recorded above and is not treated
as acceptance evidence.

Mac installation/input-source validation remains deliberately deferred per the
user's instruction and is not evidence for or against this iOS TestFlight build.
