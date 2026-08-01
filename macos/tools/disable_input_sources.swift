import Carbon
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: disable_input_sources.swift BUNDLE_ID\n", stderr)
    exit(2)
}

let bundleIdentifier = CommandLine.arguments[1]
let lookupProperties = [
    kTISPropertyBundleID as String: bundleIdentifier,
] as CFDictionary

guard let unmanaged = TISCreateInputSourceList(lookupProperties, true) else {
    fputs("TISCreateInputSourceList returned nil\n", stderr)
    exit(1)
}
let sources = unmanaged.takeRetainedValue() as! [TISInputSource]

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

// Disable selectable modes first, then their non-selectable container. This
// prevents a removed bundle from reappearing as a phantom enabled row when it
// is installed again later.
let orderedSources = sources.sorted {
    inputSourceType($0) == kTISTypeKeyboardInputMode &&
        inputSourceType($1) != kTISTypeKeyboardInputMode
}
for source in orderedSources {
    let status = TISDisableInputSource(source)
    guard status == noErr else {
        fputs("TISDisableInputSource failed: \(status)\n", stderr)
        exit(1)
    }
}
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
print("disabled_sources=\(sources.count)")
