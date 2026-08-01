import Carbon
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard
    arguments.count == 2,
    let appPath = arguments.first,
    arguments[1] == "--select"
else {
    fputs(
        "usage: register_input_source.swift INPUT_METHOD.app --select\n",
        stderr
    )
    exit(2)
}

let sourceURL = URL(fileURLWithPath: appPath) as CFURL

// Resolve the bundle up-front so we can dedupe by Bundle ID before doing any
// register/enable work.
guard
    let bundle = Bundle(url: sourceURL as URL),
    let bundleIdentifier = bundle.bundleIdentifier
else {
    fputs("Unable to read the input method bundle identifier\n", stderr)
    exit(1)
}

let lookupProperties = [
    kTISPropertyBundleID as String: bundleIdentifier,
] as CFDictionary

// Note on the historical "quiesce-then-reregister" pattern this script used
// to carry: TIS does not expose a public "unregister" API, and entry counts
// observed via TISCreateInputSourceList drift between calls inside the same
// process (the input manager mutates state concurrently). Disabling existing
// entries mid-script is therefore unreliable, and the resulting "enabled only
// the new ones" step does not actually converge on a single enabled pair.
//
// The real idempotency lives one level up the stack, in
// `script/install_debug_input_method.sh`: it moves any pre-existing copy out
// of `~/Library/Input Methods/` and ditto-installs the freshly-built bundle.
// It deliberately leaves activation to Keyboard Settings. This separate
// helper's job is only to (1) teach TIS about the bundle currently at
// `appPath`, (2) verify that it exposes a selectable keyboard mode, and (3)
// enable/select that mode for this explicit user-selection command — without crashing
// when the bundle's identifier does not match any previously-registered
// source (which is the common case on a fresh install or after a stale
// rebuild).
let status = TISRegisterInputSource(sourceURL)
guard status == noErr else {
    fputs("TISRegisterInputSource failed: \(status)\n", stderr)
    exit(1)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

// Note: `TISCreateInputSourceList` returns `Unmanaged<CFArray>!` — an
// implicitly-unwrapped Optional. Chaining `.takeRetainedValue()` on the
// return value without an explicit nil check would crash on stale builds
// (where the bundle identifier does not match any registered source). Keep
// the unwrap explicit.
guard let unmanaged = TISCreateInputSourceList(lookupProperties, true) else {
    fputs(
        "TISCreateInputSourceList returned nil for \(bundleIdentifier)\n",
        stderr
    )
    exit(1)
}
guard let sources = (unmanaged.takeRetainedValue() as? [TISInputSource]),
    !sources.isEmpty
else {
    fputs(
        "Input source registration produced no sources for \(bundleIdentifier)\n",
        stderr
    )
    exit(1)
}

func inputSourceType(_ source: TISInputSource) -> CFString? {
    guard let raw = TISGetInputSourceProperty(
        source,
        kTISPropertyInputSourceType
    ) else {
        return nil
    }
    return Unmanaged<CFString>
        .fromOpaque(raw)
        .takeUnretainedValue()
}

let inputModes = sources.filter {
    inputSourceType($0) == kTISTypeKeyboardInputMode
}
guard !inputModes.isEmpty else {
    fputs("Registered bundle has no keyboard input mode\n", stderr)
    exit(1)
}

let mode = inputModes[0]
let enableStatus = TISEnableInputSource(mode)
guard enableStatus == noErr else {
    fputs("TISEnableInputSource failed: \(enableStatus)\n", stderr)
    exit(1)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.5))

let selectStatus = TISSelectInputSource(mode)
guard selectStatus == noErr else {
    fputs("TISSelectInputSource failed: \(selectStatus)\n", stderr)
    exit(1)
}
