import Foundation

public enum VoiceReleasePolicyError: Error, Equatable, Sendable {
    case invalidXML
    case invalidStructure
    case duplicateKey(String)
    case unexpectedKeys([String])
    case missingKeys([String])
    case invalidValueType(key: String, expected: String)
    case invalidInteger(String)
    case unsupportedSchema(Int)
    case unsupportedRuntimeEngine(String)
    case unsupportedAssetManagement(String)
    case invalidTrustedCatalogSHA256
    case trustedCatalogSHA256Mismatch(expected: String, actual: String)
    case invalidSystemManagedProbe
    case productCatalogHasNoReleaseApprovals
    case invalidProductManagedPolicy
}

/// The signed, fail-closed authority that selects the Release helper engine.
///
/// The policy deliberately remains independent from model-supplied metadata.
/// A product-managed policy is accepted only when it names the exact canonical
/// digest of a non-empty, code-shipped trusted catalog containing valid Release
/// approvals. The currently shipped production catalog remains empty.
public struct VoiceReleasePolicy: Equatable, Sendable {
    public static let supportedSchemaVersion = 2

    public enum RuntimeEngine: String, Equatable, Sendable {
        case appleSpeech = "apple-speech"
        case productManaged = "product-managed"
    }

    public enum AssetManagement: String, Equatable, Sendable {
        case systemManaged = "system_managed"
        case productManaged = "product_managed"
    }

    public let schemaVersion: Int
    public let runtimeEngine: RuntimeEngine
    public let engineIdentifier: String
    public let assetManagement: AssetManagement
    public let releaseEligible: Bool
    public let eligibilityReason: String
    public let trustedCatalogSHA256: String

    private static let expectedKeys: Set<String> = [
        "SchemaVersion",
        "RuntimeEngine",
        "EngineIdentifier",
        "AssetManagement",
        "ReleaseEligible",
        "EligibilityReason",
        "TrustedCatalogSHA256",
    ]

    public static func decodeStrict(
        _ data: Data,
        trustedCatalog: VoiceASRTrustedArtifactCatalog = .production
    ) throws -> Self {
        let values = try VoiceReleasePolicyXMLDecoder.decode(data)
        let actualKeys = Set(values.keys)
        let unexpected = actualKeys.subtracting(expectedKeys).sorted()
        guard unexpected.isEmpty else {
            throw VoiceReleasePolicyError.unexpectedKeys(unexpected)
        }
        let missing = expectedKeys.subtracting(actualKeys).sorted()
        guard missing.isEmpty else {
            throw VoiceReleasePolicyError.missingKeys(missing)
        }

        let schemaVersion = try integer(
            values["SchemaVersion"],
            key: "SchemaVersion"
        )
        guard schemaVersion == supportedSchemaVersion else {
            throw VoiceReleasePolicyError.unsupportedSchema(schemaVersion)
        }
        let runtimeEngineValue = try string(
            values["RuntimeEngine"],
            key: "RuntimeEngine"
        )
        guard let runtimeEngine = RuntimeEngine(
            rawValue: runtimeEngineValue
        ) else {
            throw VoiceReleasePolicyError.unsupportedRuntimeEngine(
                runtimeEngineValue
            )
        }
        let engineIdentifier = try string(
            values["EngineIdentifier"],
            key: "EngineIdentifier"
        )
        let assetManagementValue = try string(
            values["AssetManagement"],
            key: "AssetManagement"
        )
        guard let assetManagement = AssetManagement(
            rawValue: assetManagementValue
        ) else {
            throw VoiceReleasePolicyError.unsupportedAssetManagement(
                assetManagementValue
            )
        }
        let releaseEligible = try boolean(
            values["ReleaseEligible"],
            key: "ReleaseEligible"
        )
        let eligibilityReason = try string(
            values["EligibilityReason"],
            key: "EligibilityReason"
        )
        let catalogDigest = try string(
            values["TrustedCatalogSHA256"],
            key: "TrustedCatalogSHA256"
        )
        guard isSHA256(catalogDigest) else {
            throw VoiceReleasePolicyError.invalidTrustedCatalogSHA256
        }
        let actualCatalogDigest = trustedCatalog.canonicalSHA256
        guard catalogDigest == actualCatalogDigest else {
            throw VoiceReleasePolicyError.trustedCatalogSHA256Mismatch(
                expected: actualCatalogDigest,
                actual: catalogDigest
            )
        }

        switch runtimeEngine {
        case .appleSpeech:
            guard engineIdentifier == "apple-speech-ondevice",
                  assetManagement == .systemManaged,
                  !releaseEligible,
                  eligibilityReason
                    == "macos14_15_system_managed_probe_only"
            else {
                throw VoiceReleasePolicyError.invalidSystemManagedProbe
            }
        case .productManaged:
            guard !trustedCatalog.isEmpty,
                  trustedCatalog.hasReleaseApprovals
            else {
                throw VoiceReleasePolicyError
                    .productCatalogHasNoReleaseApprovals
            }
            guard assetManagement == .productManaged,
                  releaseEligible,
                  isControlledValue(
                      engineIdentifier,
                      maximumBytes: 128
                  ),
                  isControlledValue(
                      eligibilityReason,
                      maximumBytes: 128
                  )
            else {
                throw VoiceReleasePolicyError.invalidProductManagedPolicy
            }
        }

        return Self(
            schemaVersion: schemaVersion,
            runtimeEngine: runtimeEngine,
            engineIdentifier: engineIdentifier,
            assetManagement: assetManagement,
            releaseEligible: releaseEligible,
            eligibilityReason: eligibilityReason,
            trustedCatalogSHA256: catalogDigest
        )
    }

    private static func string(
        _ value: VoiceReleasePolicyXMLValue?,
        key: String
    ) throws -> String {
        guard case let .string(result)? = value else {
            throw VoiceReleasePolicyError.invalidValueType(
                key: key,
                expected: "string"
            )
        }
        return result
    }

    private static func integer(
        _ value: VoiceReleasePolicyXMLValue?,
        key: String
    ) throws -> Int {
        guard case let .integer(rawValue)? = value else {
            throw VoiceReleasePolicyError.invalidValueType(
                key: key,
                expected: "integer"
            )
        }
        guard isCanonicalInteger(rawValue),
              let result = Int(rawValue)
        else {
            throw VoiceReleasePolicyError.invalidInteger(rawValue)
        }
        return result
    }

    private static func boolean(
        _ value: VoiceReleasePolicyXMLValue?,
        key: String
    ) throws -> Bool {
        guard case let .boolean(result)? = value else {
            throw VoiceReleasePolicyError.invalidValueType(
                key: key,
                expected: "boolean"
            )
        }
        return result
    }

    private static func isCanonicalInteger(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value == "0" { return true }
        let bytes = Array(value.utf8)
        if bytes.first == 0x2D {
            return bytes.count > 1
                && bytes[1] >= 0x31
                && bytes[1] <= 0x39
                && bytes.dropFirst(2).allSatisfy {
                    $0 >= 0x30 && $0 <= 0x39
                }
        }
        return bytes[0] >= 0x31
            && bytes[0] <= 0x39
            && bytes.dropFirst().allSatisfy {
                $0 >= 0x30 && $0 <= 0x39
            }
    }

    private static func isControlledValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

private enum VoiceReleasePolicyXMLValue: Equatable {
    case string(String)
    case integer(String)
    case boolean(Bool)
}

private final class VoiceReleasePolicyXMLDecoder:
    NSObject,
    XMLParserDelegate
{
    private enum Phase: Equatable {
        case beforePlist
        case beforeDictionary
        case expectingKey
        case readingKey
        case expectingValue
        case readingString
        case readingInteger
        case readingBoolean(String)
        case afterDictionary
        case afterPlist
    }

    private static let maximumPolicyBytes = 65_536

    private var phase: Phase = .beforePlist
    private var currentText = ""
    private var currentKey: String?
    private var values: [String: VoiceReleasePolicyXMLValue] = [:]
    private var failure: VoiceReleasePolicyError?
    private weak var parser: XMLParser?

    static func decode(
        _ data: Data
    ) throws -> [String: VoiceReleasePolicyXMLValue] {
        guard !data.isEmpty,
              data.count <= maximumPolicyBytes,
              String(data: data, encoding: .utf8) != nil
        else {
            throw VoiceReleasePolicyError.invalidXML
        }
        let delegate = VoiceReleasePolicyXMLDecoder()
        let parser = XMLParser(data: data)
        delegate.parser = parser
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        guard parsed, delegate.phase == .afterPlist else {
            throw VoiceReleasePolicyError.invalidXML
        }
        return delegate.values
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        if namespaceURI?.isEmpty == false || qName != nil {
            fail(.invalidStructure)
            return
        }
        switch phase {
        case .beforePlist:
            guard elementName == "plist",
                  attributeDict == ["version": "1.0"]
            else {
                fail(.invalidStructure)
                return
            }
            phase = .beforeDictionary
        case .beforeDictionary:
            guard elementName == "dict", attributeDict.isEmpty else {
                fail(.invalidStructure)
                return
            }
            phase = .expectingKey
        case .expectingKey:
            guard elementName == "key", attributeDict.isEmpty else {
                fail(.invalidStructure)
                return
            }
            currentText = ""
            phase = .readingKey
        case .expectingValue:
            guard attributeDict.isEmpty else {
                fail(.invalidStructure)
                return
            }
            currentText = ""
            switch elementName {
            case "string":
                phase = .readingString
            case "integer":
                phase = .readingInteger
            case "true", "false":
                phase = .readingBoolean(elementName)
            default:
                fail(.invalidStructure)
            }
        case .readingKey, .readingString, .readingInteger,
             .readingBoolean, .afterDictionary, .afterPlist:
            fail(.invalidStructure)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        switch phase {
        case .readingKey:
            guard elementName == "key", !currentText.isEmpty else {
                fail(.invalidStructure)
                return
            }
            guard values[currentText] == nil,
                  currentKey != currentText
            else {
                fail(.duplicateKey(currentText))
                return
            }
            currentKey = currentText
            currentText = ""
            phase = .expectingValue
        case .readingString:
            guard elementName == "string" else {
                fail(.invalidStructure)
                return
            }
            store(.string(currentText))
        case .readingInteger:
            guard elementName == "integer" else {
                fail(.invalidStructure)
                return
            }
            store(.integer(currentText))
        case let .readingBoolean(expectedElement):
            guard elementName == expectedElement, currentText.isEmpty else {
                fail(.invalidStructure)
                return
            }
            store(.boolean(expectedElement == "true"))
        case .expectingKey:
            guard elementName == "dict" else {
                fail(.invalidStructure)
                return
            }
            phase = .afterDictionary
        case .afterDictionary:
            guard elementName == "plist" else {
                fail(.invalidStructure)
                return
            }
            phase = .afterPlist
        case .beforePlist, .beforeDictionary, .expectingValue,
             .afterPlist:
            fail(.invalidStructure)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil else { return }
        switch phase {
        case .readingKey, .readingString, .readingInteger,
             .readingBoolean:
            currentText += string
        default:
            guard string.unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) else {
                fail(.invalidStructure)
                return
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCDATA CDATABlock: Data
    ) {
        fail(.invalidStructure)
    }

    func parser(
        _ parser: XMLParser,
        foundComment comment: String
    ) {
        fail(.invalidStructure)
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        fail(.invalidStructure)
    }

    func parser(
        _ parser: XMLParser,
        foundSkippedEntityName name: String
    ) {
        fail(.invalidStructure)
    }

    func parser(
        _ parser: XMLParser,
        parseErrorOccurred parseError: Error
    ) {
        if failure == nil {
            failure = .invalidXML
        }
    }

    private func store(_ value: VoiceReleasePolicyXMLValue) {
        guard let key = currentKey else {
            fail(.invalidStructure)
            return
        }
        values[key] = value
        currentKey = nil
        currentText = ""
        phase = .expectingKey
    }

    private func fail(_ error: VoiceReleasePolicyError) {
        guard failure == nil else { return }
        failure = error
        parser?.abortParsing()
    }
}
