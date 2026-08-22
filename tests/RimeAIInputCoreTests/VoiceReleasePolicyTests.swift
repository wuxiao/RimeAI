import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice Release policy and trusted catalog")
struct VoiceReleasePolicyTests {
    @Test("repository Release policy decodes against production catalog")
    func repositoryPolicyMatchesProductionCatalog() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let policyURL = repositoryRoot
            .appendingPathComponent("macos/VoiceHelper", isDirectory: true)
            .appendingPathComponent(
                "VoiceReleasePolicy.plist",
                isDirectory: false
            )

        let policy = try VoiceReleasePolicy.decodeStrict(
            Data(contentsOf: policyURL)
        )

        #expect(policy.runtimeEngine == .appleSpeech)
        #expect(!policy.releaseEligible)
        #expect(
            policy.trustedCatalogSHA256
                == VoiceASRTrustedArtifactCatalog.production.canonicalSHA256
        )
    }

    @Test("production catalog stays empty with a stable canonical digest")
    func productionCatalogIsEmpty() throws {
        let catalog = VoiceASRTrustedArtifactCatalog.production

        #expect(catalog.isEmpty)
        #expect(!catalog.hasReleaseApprovals)
        #expect(
            catalog.canonicalSHA256
                == "b0c8659b59e05d39683c4d9c50126f736eb620ba5c2d9c0ef925bba1d275b499"
        )

        let policy = try VoiceReleasePolicy.decodeStrict(
            systemPolicyXML(catalogSHA256: catalog.canonicalSHA256)
        )
        #expect(policy.schemaVersion == 2)
        #expect(policy.runtimeEngine == .appleSpeech)
        #expect(policy.engineIdentifier == "apple-speech-ondevice")
        #expect(policy.assetManagement == .systemManaged)
        #expect(!policy.releaseEligible)
        #expect(
            policy.eligibilityReason
                == "macos14_15_system_managed_probe_only"
        )
        #expect(policy.trustedCatalogSHA256 == catalog.canonicalSHA256)
    }

    @Test("product policy requires and binds a valid release catalog")
    func productPolicyBindsCatalog() throws {
        let catalog = trustedCatalog([releaseApproval()])
        #expect(!catalog.isEmpty)
        #expect(catalog.hasReleaseApprovals)

        let policy = try VoiceReleasePolicy.decodeStrict(
            productPolicyXML(catalogSHA256: catalog.canonicalSHA256),
            trustedCatalog: catalog
        )

        #expect(policy.runtimeEngine == .productManaged)
        #expect(policy.engineIdentifier == "sherpa-onnx")
        #expect(policy.assetManagement == .productManaged)
        #expect(policy.releaseEligible)
        #expect(policy.eligibilityReason == "v0_v1_release_gates_passed")
        #expect(policy.trustedCatalogSHA256 == catalog.canonicalSHA256)
    }

    @Test("catalog digest is order independent and covers every approval field")
    func catalogDigestContract() {
        let first = releaseApproval()
        let second = releaseApproval(
            artifactID: "sherpa-zipformer-zh-en-int8-v2",
            contentSHA256: String(repeating: "b", count: 64),
            modelRevision: "revision-2"
        )
        let forward = trustedCatalog([first, second])
        let reverse = trustedCatalog([second, first])
        #expect(forward.canonicalSHA256 == reverse.canonicalSHA256)
        #expect(forward.hasReleaseApprovals)

        let variants = [
            releaseApproval(artifactID: "different-artifact"),
            releaseApproval(
                contentSHA256: String(repeating: "c", count: 64)
            ),
            releaseApproval(adapterID: "different-adapter"),
            releaseApproval(adapterVersion: "2.0.0"),
            releaseApproval(adapterABIVersion: 2),
            releaseApproval(modelID: "different-model"),
            releaseApproval(modelRevision: "different-revision"),
            releaseApproval(modelFormat: .coreML),
            releaseApproval(modelQuantization: .fp16),
            releaseApproval(licenseSPDXID: "MIT"),
            releaseApproval(licensePath: "licenses/COPYING.txt"),
            releaseApproval(noticePath: "licenses/ATTRIBUTION.txt"),
            releaseApproval(
                sourceURL: "https://example.invalid/other-model-card"
            ),
            releaseApproval(redistributionApproved: false),
            releaseApproval(releaseEvidence: approvedReleaseEvidence(
                sourceReviewID: "source-review-2026-08-22"
            )),
            releaseApproval(releaseEvidence: approvedReleaseEvidence(
                modelRightsReviewID: "model-rights-review-2026-08-22"
            )),
            releaseApproval(releaseEvidence: approvedReleaseEvidence(
                redistributionReviewID:
                    "redistribution-review-2026-08-22"
            )),
            releaseApproval(releaseEvidence: approvedReleaseEvidence(
                qualityReportSHA256: String(repeating: "e", count: 64)
            )),
        ]
        let baselineDigest = trustedCatalog([first]).canonicalSHA256
        #expect(
            variants.allSatisfy {
                trustedCatalog([$0]).canonicalSHA256 != baselineDigest
            }
        )
        #expect(
            Set(variants.map {
                trustedCatalog([$0]).canonicalSHA256
            }).count == variants.count
        )
    }

    @Test("only a wholly valid and unambiguous catalog has release approvals")
    func releaseApprovalValidity() {
        #expect(
            !trustedCatalog([
                releaseApproval(redistributionApproved: false),
            ]).hasReleaseApprovals
        )
        #expect(
            !trustedCatalog([
                releaseApproval(contentSHA256: "not-a-sha256"),
            ]).hasReleaseApprovals
        )
        #expect(
            !trustedCatalog([
                releaseApproval(),
                releaseApproval(modelRevision: "same-id-other-revision"),
            ]).hasReleaseApprovals
        )
        #expect(
            !trustedCatalog([
                releaseApproval(),
                releaseApproval(
                    artifactID: "second-artifact",
                    redistributionApproved: false
                ),
            ]).hasReleaseApprovals
        )
    }

    @Test("release approval requires complete, strictly shaped evidence")
    func releaseEvidenceValidity() {
        #expect(trustedCatalog([releaseApproval()]).hasReleaseApprovals)

        let invalidEvidence = [
            approvedReleaseEvidence(sourceReviewID: ""),
            approvedReleaseEvidence(modelRightsReviewID: "review id"),
            approvedReleaseEvidence(redistributionReviewID: "review/id"),
            approvedReleaseEvidence(
                sourceReviewID: String(repeating: "s", count: 129)
            ),
            approvedReleaseEvidence(qualityReportSHA256: "not-a-sha256"),
            approvedReleaseEvidence(
                qualityReportSHA256: String(repeating: "A", count: 64)
            ),
        ]
        #expect(
            invalidEvidence.allSatisfy { evidence in
                !trustedCatalog([
                    releaseApproval(releaseEvidence: evidence),
                ]).hasReleaseApprovals
            }
        )
    }

    @Test("non-XML and non-flat policies are rejected")
    func rejectsNonXMLAndNonFlatPolicies() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["SchemaVersion": 2],
            format: .binary,
            options: 0
        )
        #expect(throws: VoiceReleasePolicyError.invalidXML) {
            try VoiceReleasePolicy.decodeStrict(binary)
        }
        #expect(throws: VoiceReleasePolicyError.invalidStructure) {
            try VoiceReleasePolicy.decodeStrict(Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <key>SchemaVersion</key><dict/>
                </dict></plist>
                """.utf8
            ))
        }
        #expect(throws: VoiceReleasePolicyError.invalidStructure) {
            try VoiceReleasePolicy.decodeStrict(Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <!-- policy comments are not canonical -->
                  <key>SchemaVersion</key><integer>2</integer>
                </dict></plist>
                """.utf8
            ))
        }
    }

    @Test("duplicate and transformed keys are rejected")
    func rejectsDuplicateAndTransformedKeys() {
        let digest = VoiceASRTrustedArtifactCatalog.production.canonicalSHA256
        let duplicate = systemPolicyXML(
            catalogSHA256: digest,
            entries: systemEntries(catalogSHA256: digest) + [
                ("RuntimeEngine", .string("apple-speech")),
            ]
        )
        #expect(
            throws: VoiceReleasePolicyError.duplicateKey("RuntimeEngine")
        ) {
            try VoiceReleasePolicy.decodeStrict(duplicate)
        }

        let entityDuplicate = Data(
            policyDocument(body: """
              <key>Runtime&#69;ngine</key><string>apple-speech</string>
              <key>RuntimeEngine</key><string>apple-speech</string>
            """).utf8
        )
        #expect(
            throws: VoiceReleasePolicyError.duplicateKey("RuntimeEngine")
        ) {
            try VoiceReleasePolicy.decodeStrict(entityDuplicate)
        }

        let transformed = String(
            data: systemPolicyXML(catalogSHA256: digest),
            encoding: .utf8
        )!.replacingOccurrences(
            of: "<key>RuntimeEngine</key>",
            with: "<key>runtimeEngine</key>"
        )
        #expect(
            throws: VoiceReleasePolicyError.unexpectedKeys([
                "runtimeEngine",
            ])
        ) {
            try VoiceReleasePolicy.decodeStrict(Data(transformed.utf8))
        }
    }

    @Test("missing, extra, and wrongly typed keys are rejected")
    func rejectsInvalidKeySetAndTypes() {
        let digest = VoiceASRTrustedArtifactCatalog.production.canonicalSHA256
        var missingEntries = systemEntries(catalogSHA256: digest)
        missingEntries.removeAll { $0.0 == "EligibilityReason" }
        #expect(
            throws: VoiceReleasePolicyError.missingKeys([
                "EligibilityReason",
            ])
        ) {
            try VoiceReleasePolicy.decodeStrict(systemPolicyXML(
                catalogSHA256: digest,
                entries: missingEntries
            ))
        }

        let extraEntries = systemEntries(catalogSHA256: digest) + [
            ("Unexpected", .string("value")),
        ]
        #expect(
            throws: VoiceReleasePolicyError.unexpectedKeys(["Unexpected"])
        ) {
            try VoiceReleasePolicy.decodeStrict(systemPolicyXML(
                catalogSHA256: digest,
                entries: extraEntries
            ))
        }

        var wrongTypeEntries = systemEntries(catalogSHA256: digest)
        let eligibilityIndex = wrongTypeEntries.firstIndex {
            $0.0 == "ReleaseEligible"
        }!
        wrongTypeEntries[eligibilityIndex] = (
            "ReleaseEligible",
            .string("false")
        )
        #expect(
            throws: VoiceReleasePolicyError.invalidValueType(
                key: "ReleaseEligible",
                expected: "boolean"
            )
        ) {
            try VoiceReleasePolicy.decodeStrict(systemPolicyXML(
                catalogSHA256: digest,
                entries: wrongTypeEntries
            ))
        }
    }

    @Test("schema and catalog digest must match exactly")
    func rejectsSchemaAndCatalogDigestMismatch() {
        let catalog = VoiceASRTrustedArtifactCatalog.production
        var schemaEntries = systemEntries(
            catalogSHA256: catalog.canonicalSHA256
        )
        let schemaIndex = schemaEntries.firstIndex {
            $0.0 == "SchemaVersion"
        }!
        schemaEntries[schemaIndex] = ("SchemaVersion", .integer("1"))
        #expect(throws: VoiceReleasePolicyError.unsupportedSchema(1)) {
            try VoiceReleasePolicy.decodeStrict(systemPolicyXML(
                catalogSHA256: catalog.canonicalSHA256,
                entries: schemaEntries
            ))
        }

        #expect(
            throws: VoiceReleasePolicyError.invalidTrustedCatalogSHA256
        ) {
            try VoiceReleasePolicy.decodeStrict(systemPolicyXML(
                catalogSHA256: "ABC"
            ))
        }

        let mismatched = String(repeating: "f", count: 64)
        #expect(
            throws: VoiceReleasePolicyError
                .trustedCatalogSHA256Mismatch(
                    expected: catalog.canonicalSHA256,
                    actual: mismatched
                )
        ) {
            try VoiceReleasePolicy.decodeStrict(systemPolicyXML(
                catalogSHA256: mismatched
            ))
        }
    }

    @Test("system probe is an exact fail-closed tuple")
    func systemProbeMustBeExact() {
        let digest = VoiceASRTrustedArtifactCatalog.production.canonicalSHA256
        let invalidPolicies = [
            policyXML(
                runtimeEngine: "apple-speech",
                engineIdentifier: "other-engine",
                assetManagement: "system_managed",
                releaseEligible: false,
                eligibilityReason: "macos14_15_system_managed_probe_only",
                catalogSHA256: digest
            ),
            policyXML(
                runtimeEngine: "apple-speech",
                engineIdentifier: "apple-speech-ondevice",
                assetManagement: "product_managed",
                releaseEligible: false,
                eligibilityReason: "macos14_15_system_managed_probe_only",
                catalogSHA256: digest
            ),
            policyXML(
                runtimeEngine: "apple-speech",
                engineIdentifier: "apple-speech-ondevice",
                assetManagement: "system_managed",
                releaseEligible: true,
                eligibilityReason: "macos14_15_system_managed_probe_only",
                catalogSHA256: digest
            ),
            policyXML(
                runtimeEngine: "apple-speech",
                engineIdentifier: "apple-speech-ondevice",
                assetManagement: "system_managed",
                releaseEligible: false,
                eligibilityReason: "different-reason",
                catalogSHA256: digest
            ),
        ]
        for policy in invalidPolicies {
            #expect(
                throws: VoiceReleasePolicyError.invalidSystemManagedProbe
            ) {
                try VoiceReleasePolicy.decodeStrict(policy)
            }
        }
    }

    @Test("product policy rejects empty, invalid, and uncontrolled catalogs")
    func productPolicyMustBeReleaseApproved() {
        let production = VoiceASRTrustedArtifactCatalog.production
        #expect(
            throws: VoiceReleasePolicyError
                .productCatalogHasNoReleaseApprovals
        ) {
            try VoiceReleasePolicy.decodeStrict(
                productPolicyXML(
                    catalogSHA256: production.canonicalSHA256
                )
            )
        }

        let invalidCatalog = trustedCatalog([
            releaseApproval(redistributionApproved: false),
        ])
        #expect(
            throws: VoiceReleasePolicyError
                .productCatalogHasNoReleaseApprovals
        ) {
            try VoiceReleasePolicy.decodeStrict(
                productPolicyXML(
                    catalogSHA256: invalidCatalog.canonicalSHA256
                ),
                trustedCatalog: invalidCatalog
            )
        }

        let validCatalog = trustedCatalog([releaseApproval()])
        let invalidPolicies = [
            policyXML(
                runtimeEngine: "product-managed",
                engineIdentifier: "sherpa-onnx",
                assetManagement: "system_managed",
                releaseEligible: true,
                eligibilityReason: "v0_v1_release_gates_passed",
                catalogSHA256: validCatalog.canonicalSHA256
            ),
            policyXML(
                runtimeEngine: "product-managed",
                engineIdentifier: "sherpa-onnx",
                assetManagement: "product_managed",
                releaseEligible: false,
                eligibilityReason: "v0_v1_release_gates_passed",
                catalogSHA256: validCatalog.canonicalSHA256
            ),
            policyXML(
                runtimeEngine: "product-managed",
                engineIdentifier: "bad engine",
                assetManagement: "product_managed",
                releaseEligible: true,
                eligibilityReason: "v0_v1_release_gates_passed",
                catalogSHA256: validCatalog.canonicalSHA256
            ),
            policyXML(
                runtimeEngine: "product-managed",
                engineIdentifier: "sherpa-onnx",
                assetManagement: "product_managed",
                releaseEligible: true,
                eligibilityReason: "",
                catalogSHA256: validCatalog.canonicalSHA256
            ),
        ]
        for policy in invalidPolicies {
            #expect(
                throws: VoiceReleasePolicyError.invalidProductManagedPolicy
            ) {
                try VoiceReleasePolicy.decodeStrict(
                    policy,
                    trustedCatalog: validCatalog
                )
            }
        }
    }

    @Test("unsupported engine and asset values are rejected")
    func rejectsUnsupportedModes() {
        let digest = VoiceASRTrustedArtifactCatalog.production.canonicalSHA256
        #expect(
            throws: VoiceReleasePolicyError.unsupportedRuntimeEngine(
                "cloud"
            )
        ) {
            try VoiceReleasePolicy.decodeStrict(policyXML(
                runtimeEngine: "cloud",
                engineIdentifier: "cloud",
                assetManagement: "system_managed",
                releaseEligible: false,
                eligibilityReason: "reason",
                catalogSHA256: digest
            ))
        }
        #expect(
            throws: VoiceReleasePolicyError.unsupportedAssetManagement(
                "downloaded"
            )
        ) {
            try VoiceReleasePolicy.decodeStrict(policyXML(
                runtimeEngine: "apple-speech",
                engineIdentifier: "apple-speech-ondevice",
                assetManagement: "downloaded",
                releaseEligible: false,
                eligibilityReason: "macos14_15_system_managed_probe_only",
                catalogSHA256: digest
            ))
        }
    }
}

private enum PolicyTestValue {
    case string(String)
    case integer(String)
    case boolean(Bool)

    var xml: String {
        switch self {
        case let .string(value):
            return "<string>\(escapeXML(value))</string>"
        case let .integer(value):
            return "<integer>\(escapeXML(value))</integer>"
        case let .boolean(value):
            return value ? "<true/>" : "<false/>"
        }
    }
}

private func systemPolicyXML(
    catalogSHA256: String,
    entries: [(String, PolicyTestValue)]? = nil
) -> Data {
    policyXML(entries: entries ?? systemEntries(
        catalogSHA256: catalogSHA256
    ))
}

private func productPolicyXML(catalogSHA256: String) -> Data {
    policyXML(
        runtimeEngine: "product-managed",
        engineIdentifier: "sherpa-onnx",
        assetManagement: "product_managed",
        releaseEligible: true,
        eligibilityReason: "v0_v1_release_gates_passed",
        catalogSHA256: catalogSHA256
    )
}

private func policyXML(
    runtimeEngine: String,
    engineIdentifier: String,
    assetManagement: String,
    releaseEligible: Bool,
    eligibilityReason: String,
    catalogSHA256: String
) -> Data {
    policyXML(entries: [
        ("SchemaVersion", .integer("2")),
        ("RuntimeEngine", .string(runtimeEngine)),
        ("EngineIdentifier", .string(engineIdentifier)),
        ("AssetManagement", .string(assetManagement)),
        ("ReleaseEligible", .boolean(releaseEligible)),
        ("EligibilityReason", .string(eligibilityReason)),
        ("TrustedCatalogSHA256", .string(catalogSHA256)),
    ])
}

private func systemEntries(
    catalogSHA256: String
) -> [(String, PolicyTestValue)] {
    [
        ("SchemaVersion", .integer("2")),
        ("RuntimeEngine", .string("apple-speech")),
        ("EngineIdentifier", .string("apple-speech-ondevice")),
        ("AssetManagement", .string("system_managed")),
        ("ReleaseEligible", .boolean(false)),
        (
            "EligibilityReason",
            .string("macos14_15_system_managed_probe_only")
        ),
        ("TrustedCatalogSHA256", .string(catalogSHA256)),
    ]
}

private func policyXML(entries: [(String, PolicyTestValue)]) -> Data {
    let body = entries.map { key, value in
        "  <key>\(escapeXML(key))</key>\(value.xml)"
    }.joined(separator: "\n")
    return Data(policyDocument(body: body).utf8)
}

private func policyDocument(body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \(body)
    </dict>
    </plist>
    """
}

private func escapeXML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func trustedCatalog(
    _ approvals: [VoiceASRTrustedArtifactApproval]
) -> VoiceASRTrustedArtifactCatalog {
    VoiceASRTrustedArtifactCatalog(approvals: approvals)
}

private func releaseApproval(
    artifactID: String = "sherpa-zipformer-zh-en-int8-v1",
    contentSHA256: String = String(repeating: "a", count: 64),
    adapterID: String = "sherpa-onnx",
    adapterVersion: String = "1.13.6",
    adapterABIVersion: Int = 1,
    modelID: String = "zipformer-zh-en",
    modelRevision: String = "revision-1",
    modelFormat: VoiceASRArtifactManifest.ModelFormat = .onnx,
    modelQuantization: VoiceASRArtifactManifest.ModelQuantization = .int8,
    licenseSPDXID: String = "Apache-2.0",
    licensePath: String = "licenses/LICENSE.txt",
    noticePath: String = "licenses/NOTICE.txt",
    sourceURL: String = "https://example.invalid/model-card",
    redistributionApproved: Bool = true,
    releaseEvidence: VoiceASRReleaseEvidence = approvedReleaseEvidence()
) -> VoiceASRTrustedArtifactApproval {
    VoiceASRTrustedArtifactApproval(
        artifactID: VoiceASRArtifactID(rawValue: artifactID)!,
        contentSHA256: contentSHA256,
        adapterID: adapterID,
        adapterVersion: adapterVersion,
        adapterABIVersion: adapterABIVersion,
        modelID: modelID,
        modelRevision: modelRevision,
        modelFormat: modelFormat,
        modelQuantization: modelQuantization,
        licenseSPDXID: licenseSPDXID,
        licensePath: licensePath,
        noticePath: noticePath,
        sourceURL: sourceURL,
        redistributionApproved: redistributionApproved,
        releaseEvidence: releaseEvidence
    )
}

private func approvedReleaseEvidence(
    sourceReviewID: String = "source-review-2026-08-21",
    modelRightsReviewID: String = "model-rights-review-2026-08-21",
    redistributionReviewID: String = "redistribution-review-2026-08-21",
    qualityReportSHA256: String = String(repeating: "d", count: 64)
) -> VoiceASRReleaseEvidence {
    VoiceASRReleaseEvidence(
        sourceReviewID: sourceReviewID,
        modelRightsReviewID: modelRightsReviewID,
        redistributionReviewID: redistributionReviewID,
        qualityReportSHA256: qualityReportSHA256
    )
}
