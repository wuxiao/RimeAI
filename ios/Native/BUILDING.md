# RimeAI iOS native artifact

`RimeAINative.xcframework` is a checked-in internal-release artifact built
from source for two distinct destinations:

- `arm64-apple-ios17.0`
- `arm64-apple-ios17.0-simulator`

The authoritative source revisions, Boost archive digest, build-helper
revision, disabled librime options, and deployment target are recorded in
`artifact-lock.json`. The build does not consume the Homebrew librime bottle.

The current artifact was produced with:

- librime logging disabled;
- external plugins disabled;
- timestamps disabled;
- static LevelDB, marisa-trie, OpenCC, yaml-cpp, and Boost.Regex;
- OpenCC tools/data generated in a separate macOS host build;
- a separate CMake build directory and install prefix for device and Simulator;
- `xcodebuild -create-xcframework` over the two final static archives.

Before replacing the artifact:

1. Verify every downloaded revision and the Boost archive SHA-256 against
   `artifact-lock.json`.
2. Build device and Simulator independently with iOS 17.0 as the explicit
   deployment target.
3. Do not add a macOS or Catalyst slice.
4. Regenerate the XCFramework and update the lock only when a source or build
   input deliberately changes.
5. Run the integration and system-keyboard UI tests, then make a signed Release
   archive and inspect the archived extension's minimum OS and entitlements.

The checked-in license texts under `../ThirdPartyLicenses` must be regenerated
from the exact pinned sources when any dependency revision changes.
