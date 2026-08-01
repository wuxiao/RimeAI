import Carbon
import Foundation

private func stringProperty(
    _ source: TISInputSource,
    _ key: CFString
) -> String? {
    guard let raw = TISGetInputSourceProperty(source, key) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

private func boolProperty(
    _ source: TISInputSource,
    _ key: CFString
) -> Bool? {
    guard let raw = TISGetInputSourceProperty(source, key) else {
        return nil
    }
    let value = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
    return CFBooleanGetValue(value)
}

private func stringArrayProperty(
    _ source: TISInputSource,
    _ key: CFString
) -> [String]? {
    guard let raw = TISGetInputSourceProperty(source, key) else {
        return nil
    }
    return Unmanaged<CFArray>.fromOpaque(raw)
        .takeUnretainedValue() as? [String]
}

let needle = CommandLine.arguments.dropFirst().first?.lowercased()
let sources = TISCreateInputSourceList(nil, true)
    .takeRetainedValue() as! [TISInputSource]

for source in sources {
    let identifier = stringProperty(source, kTISPropertyInputSourceID) ?? ""
    let bundleIdentifier = stringProperty(source, kTISPropertyBundleID) ?? ""
    let localizedName = stringProperty(source, kTISPropertyLocalizedName) ?? ""
    let modeIdentifier = stringProperty(source, kTISPropertyInputModeID) ?? ""
    let type = stringProperty(source, kTISPropertyInputSourceType) ?? ""
    let searchable = [
        identifier,
        bundleIdentifier,
        localizedName,
        modeIdentifier,
        type,
    ].joined(separator: "\n").lowercased()

    if let needle, !searchable.contains(needle) {
        continue
    }

    let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
    let selected = boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
    let enableCapable =
        boolProperty(source, kTISPropertyInputSourceIsEnableCapable) ?? false
    let selectCapable =
        boolProperty(source, kTISPropertyInputSourceIsSelectCapable) ?? false
    let category =
        stringProperty(source, kTISPropertyInputSourceCategory) ?? ""
    let languages =
        stringArrayProperty(source, kTISPropertyInputSourceLanguages) ?? []
    let asciiCapable =
        boolProperty(source, kTISPropertyInputSourceIsASCIICapable) ?? false
    print(
        [
            "id=\(identifier)",
            "bundle=\(bundleIdentifier)",
            "mode=\(modeIdentifier)",
            "type=\(type)",
            "category=\(category)",
            "name=\(localizedName)",
            "languages=\(languages.joined(separator: ","))",
            "asciiCapable=\(asciiCapable)",
            "enabled=\(enabled)",
            "enableCapable=\(enableCapable)",
            "selectCapable=\(selectCapable)",
            "selected=\(selected)",
        ].joined(separator: "\t")
    )
}
