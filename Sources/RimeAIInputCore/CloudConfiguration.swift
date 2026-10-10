import Foundation

/// Platform-neutral cloud service identifiers shared by settings documents
/// and the macOS credential implementation. Credentials themselves remain in
/// `CloudCredentialStore.swift` and are never part of settings import/export.
public enum RimeAICloudConfiguration {
    public static let provider = "wwcn New API Gateway"
    public static let endpoint = URL(
        string: "https://newapi.wwcn.fun/v1"
    )!
    public static let rankingModelIDs = [
        "glm-5.3-flash",
        "glm-5.3",
    ]
    public static let defaultRankingModelID = rankingModelIDs[0]
    public static let embeddingModelID = "text-embedding-v4"
    public static let embeddingDimensions = 512
    public static let credentialKey = "RIMEAI_CLOUD_API_KEY"
}
