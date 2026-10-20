import Foundation

/// Errors raised while cascading phrasebook domain operations to the
/// other two learning layers.
public enum LanguageProfileArtifactsError: Error, Equatable, Sendable {
    /// The L2 user-LM artifact exists but does not have the expected
    /// shape. Surfacing it keeps the rename/delete cascade honest: a
    /// silent skip would leave the L2 counts under the old domain name
    /// while L1 and L3 already moved on.
    case malformedUserLM(String)
}

/// Cascades phrasebook domain operations to the other two learning
/// layers (P2-16): renaming or deleting a domain in the L1 phrasebook
/// must move/remove the same domain's L2 user-LM counts and L3 style
/// profile, otherwise the artifacts linger under a dead name forever.
public enum LanguageProfileArtifacts {
    /// Renames `source` to `target` across L2 and L3 artifacts.
    ///
    /// L2 user LM: the source domain's counts move under the target key;
    /// when the target already has counts (rename onto an existing
    /// domain = merge), n-gram/prefix counters and character totals are
    /// summed. L3 style profile: the current file is renamed; when the
    /// target profile already exists, the source profile is archived
    /// into the revisions directory instead of overwriting it (merge of
    /// style profiles is not defined). Revision files follow the rename.
    public static func renameDomain(
        from source: String,
        to target: String,
        in directory: URL
    ) throws {
        try updateUserLM(in: directory) { domains in
            guard let sourceCounts = domains[source] else {
                return
            }
            domains.removeValue(forKey: source)
            if let existing = domains[target] as? [String: Any],
               let incoming = sourceCounts as? [String: Any]
            {
                domains[target] = mergeDomainCounts(existing, incoming)
            } else {
                domains[target] = sourceCounts
            }
        }
        try renameStyleProfile(from: source, to: target, in: directory)
    }

    /// Deletes a domain from the L2 user LM and removes its L3 style
    /// profile plus archived revisions.
    public static func deleteDomain(
        _ domain: String,
        in directory: URL
    ) throws {
        try updateUserLM(in: directory) { domains in
            domains.removeValue(forKey: domain)
        }
        let manager = FileManager.default
        // Missing artifacts are fine (the layer may never have learned
        // this domain); other errors still surface.
        try removeIfPresent(profileURL(domain, in: directory))
        let revisions = directory.appendingPathComponent(
            "revisions",
            isDirectory: true
        )
        for item in try revisionFiles(domain, in: revisions) {
            try removeIfPresent(item)
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — the goal state.
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileNoSuchFileError
            {
                return
            }
            throw error
        }
    }

    // MARK: - L2 user LM

    private static func updateUserLM(
        in directory: URL,
        mutate: (inout [String: Any]) -> Void
    ) throws {
        let url = directory.appendingPathComponent("user-lm.json.gz")
        // A missing artifact is the normal state for a layer that never
        // ran: there is nothing to update. A present but malformed
        // artifact is an error — returning silently would leave the L2
        // counts under the old domain name while L1 and L3 already
        // moved on, breaking the cascade invariant.
        let compressed: Data
        do {
            compressed = try Data(contentsOf: url)
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        {
            return
        }
        guard !compressed.isEmpty else {
            // A zero-byte artifact is damage (the daemon writes through
            // a temporary file and renames it), not "no artifact yet":
            // skipping it silently would leave the L2 counts under the
            // old domain name.
            throw LanguageProfileArtifactsError.malformedUserLM(
                "user-lm artifact is empty"
            )
        }
        let decoded = try GzipCodec.decode(compressed)
        guard var payload = try JSONSerialization.jsonObject(with: decoded)
            as? [String: Any]
        else {
            throw LanguageProfileArtifactsError.malformedUserLM(
                "user-lm payload is not a JSON object"
            )
        }
        guard var domains = payload["domains"] as? [String: Any] else {
            throw LanguageProfileArtifactsError.malformedUserLM(
                "user-lm payload has no 'domains' object"
            )
        }
        mutate(&domains)
        payload["domains"] = domains
        let encoded = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        try GzipCodec.encode(encoded).write(
            to: url,
            options: .atomic
        )
    }

    /// Sums two DomainCounts payloads (ngram_counts / prefix_counts per
    /// order, plus characters) — the JSON mirror of Python Counter-add.
    static func mergeDomainCounts(
        _ base: [String: Any],
        _ incoming: [String: Any]
    ) -> [String: Any] {
        var merged = base
        for key in ["ngram_counts", "prefix_counts"] {
            guard let baseOrders = base[key] as? [String: Any],
                  let incomingOrders = incoming[key] as? [String: Any]
            else {
                continue
            }
            merged[key] = mergeNestedCounters(baseOrders, incomingOrders)
        }
        let characters = (base["characters"] as? Int ?? 0)
            + (incoming["characters"] as? Int ?? 0)
        merged["characters"] = characters
        return merged
    }

    private static func mergeNestedCounters(
        _ base: [String: Any],
        _ incoming: [String: Any]
    ) -> [String: Any] {
        var merged = base
        for (order, table) in incoming {
            guard let table = table as? [String: Any] else {
                continue
            }
            var mergedTable = merged[order] as? [String: Any] ?? [:]
            for (context, count) in table {
                guard let count = count as? Int else {
                    continue
                }
                let existing = mergedTable[context] as? Int ?? 0
                mergedTable[context] = existing + count
            }
            merged[order] = mergedTable
        }
        return merged
    }

    // MARK: - L3 style profiles

    private static func profileURL(
        _ domain: String,
        in directory: URL
    ) -> URL {
        directory.appendingPathComponent("profile-\(domain).json")
    }

    private static func revisionFiles(
        _ domain: String,
        in revisions: URL
    ) throws -> [URL] {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: revisions,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return items.filter {
            $0.lastPathComponent.hasPrefix("\(domain)-")
                && $0.pathExtension == "json"
        }
    }

    private static func renameStyleProfile(
        from source: String,
        to target: String,
        in directory: URL
    ) throws {
        let manager = FileManager.default
        let sourceURL = profileURL(source, in: directory)
        let targetURL = profileURL(target, in: directory)
        // Existence checks avoid `fileExists(atPath:)` (privacy-manifest
        // file-timestamp category): a readable file proves presence.
        let sourceExists = (try? Data(contentsOf: sourceURL)) != nil
        let targetExists = (try? Data(contentsOf: targetURL)) != nil
        if sourceExists {
            if targetExists {
                // Style profiles have no merge semantics; archive the
                // source into revisions so nothing is silently lost.
                let revisions = directory.appendingPathComponent(
                    "revisions",
                    isDirectory: true
                )
                try manager.createDirectory(
                    at: revisions,
                    withIntermediateDirectories: true
                )
                let stamp = Int(Date().timeIntervalSince1970 * 1000)
                var archive = revisions.appendingPathComponent(
                    "\(source)-merged-\(stamp).json"
                )
                var suffix = 0
                while (try? Data(contentsOf: archive)) != nil {
                    suffix += 1
                    archive = revisions.appendingPathComponent(
                        "\(source)-merged-\(stamp)-\(suffix).json"
                    )
                }
                try manager.moveItem(at: sourceURL, to: archive)
            } else {
                try manager.moveItem(at: sourceURL, to: targetURL)
            }
        }
        let revisions = directory.appendingPathComponent(
            "revisions",
            isDirectory: true
        )
        for item in try revisionFiles(source, in: revisions) {
            let renamed = item.lastPathComponent.replacingOccurrences(
                of: "^\(NSRegularExpression.escapedPattern(for: source))-",
                with: "\(target)-",
                options: .regularExpression
            )
            try manager.moveItem(
                at: item,
                to: revisions.appendingPathComponent(renamed)
            )
        }
    }
}
