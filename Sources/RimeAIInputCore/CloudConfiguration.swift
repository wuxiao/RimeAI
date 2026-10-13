import Foundation

/// Platform-neutral cloud service identifiers shared by settings documents
/// and the macOS credential implementation. Credentials themselves remain in
/// `CloudCredentialStore.swift` and are never part of settings import/export.
public enum RimeAICloudConfiguration {
    /// Official Zhipu Coding Plan, direct connection. Must stay byte
    /// identical to `ENDPOINT` in rimeai_cloud_broker/cloud_model.py: the broker
    /// echoes its endpoint in the hello frame and the client compares
    /// the two strings for handshake compatibility.
    public static let provider = "Zhipu Coding Plan (direct)"
    public static let endpoint = URL(
        string: "https://open.bigmodel.cn/api/coding/paas/v4"
    )!
    public static let rankingModelIDs = [
        "glm-5.3-flash",
    ]
    public static let defaultRankingModelID = rankingModelIDs[0]
    public static let embeddingModelID = "text-embedding-v4"
    public static let embeddingDimensions = 512
    public static let credentialKey = "RIMEAI_CLOUD_API_KEY"
}
