# RimeAI iOS internal feasibility build

This directory is an additive iOS host app and custom keyboard extension. It
does not replace the macOS InputMethodKit implementation.

## Stable identities

- Host app: `fun.wwcn.rimeai.app`
- Keyboard extension: `fun.wwcn.rimeai.app.keyboard`
- Apple Developer Team: `S3T42U45P8`
- App Store Connect Apple ID: `6796064035`
- App Store Connect SKU: `RIMEAI-IOS-001`
- Host App Store profile: `RimeAI iOS App App Store`
- Keyboard App Store profile: `RimeAI iOS Keyboard App Store`

`project.yml` is the canonical project definition. Regenerate the Xcode project
with:

```bash
xcodegen generate --spec ios/project.yml --project ios
```

`ExportOptions.plist` pins the App Store Connect export to Team
`S3T42U45P8` and the two app-specific provisioning profiles. A successful
archive or IPA export proves the local signing chain only; it does not prove an
upload, App Store Connect processing, TestFlight availability, or device
acceptance.

## Current internal boundary

- The extension provides lowercase ASCII/pinyin input, delete, space, return,
  a next-keyboard control, and a native librime candidate strip.
- The bundled `RimeAINative.xcframework` contains independently built iOS
  device and Apple Silicon Simulator slices targeting iOS 17.0. Exact source
  revisions are recorded in `Native/artifact-lock.json`.
- Bundled prebuilt Rime data lets the extension start without running schema
  maintenance during the keyboard extension's first-launch path.
- `RequestsOpenAccess` is `false`.
- There is no network client, shared App Group, login, push, in-app purchase, or
  background mode.
- The host app provides setup instructions and a local keyboard test field.
- Native librime candidates are available. A read-only compact artifact exactly
  reproduces the approved P0 character n-gram candidate scorer on iOS. Its
  source and artifact hashes are locked in `SemanticModel/artifact-lock.json`.
- The semantic state occupies a separate candidate slot and explicitly reports
  a promoted candidate, same-top result, low confidence, no candidate, or model
  fallback. It never reorders the stable native candidate buttons in place.
- The planned `RimeAI-Ranker-S-24M` neural ranker is not integrated on iOS.
- The Simulator integration and system-keyboard UI tests exercise `nihao` →
  `你好`, assert the visible local-model state, and load an approved ranking
  fixture. They do not replace physical-device memory, lifecycle, and host-app
  compatibility evidence.

Do not describe this feasibility build as completed iOS product support.
Before assigning an internal TestFlight build to testers, revalidate the Release
archive's signed entitlements and export declarations. Physical-device memory,
lifecycle, and real-host typing remain acceptance gates.

The host app bundles the applicable notices from `ThirdPartyLicenses`. This is
an engineering inventory, not a substitute for legal review of the Rime data
redistribution obligations.
