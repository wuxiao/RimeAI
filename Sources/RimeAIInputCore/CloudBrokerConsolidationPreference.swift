import Foundation

/// Rewrites the installed cloud-broker LaunchAgent plist so the broker
/// runs with (or without) `--no-consolidation` — the settings-side switch
/// for L3 cloud compression (LP-006). Local L1/L2 statistics keep running
/// either way; the flag only disables the LLM profile pass.
public enum CloudBrokerConsolidationPreference {
    public static let disableFlag = "--no-consolidation"

    public enum PreferenceError: Error, Equatable, Sendable {
        case malformedPlist
    }

    /// Program arguments with the consolidation flag set per `enabled`,
    /// idempotent for repeated application.
    public static func programArguments(
        _ arguments: [String],
        consolidationEnabled: Bool
    ) -> [String] {
        var cleaned = arguments.filter { $0 != disableFlag }
        if !consolidationEnabled {
            cleaned.append(disableFlag)
        }
        return cleaned
    }

    /// Applies the preference to the plist's `ProgramArguments` and
    /// returns whether the file contents changed.
    @discardableResult
    public static func apply(
        consolidationEnabled: Bool,
        to plistURL: URL
    ) throws -> Bool {
        let data = try Data(contentsOf: plistURL)
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String]
        else {
            throw PreferenceError.malformedPlist
        }
        let updated = programArguments(
            arguments,
            consolidationEnabled: consolidationEnabled
        )
        guard updated != arguments else {
            return false
        }
        var mutable = plist
        mutable["ProgramArguments"] = updated
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: mutable,
            format: .xml,
            options: 0
        )
        try encoded.write(to: plistURL, options: .atomic)
        return true
    }
}
