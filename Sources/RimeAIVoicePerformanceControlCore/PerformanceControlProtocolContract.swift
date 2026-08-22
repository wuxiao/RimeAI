import CryptoKit
import Foundation

/// The reviewed, code-owned description of performance-control wire v2.
///
/// Packaging consumes `identity`; callers cannot substitute contract bytes or
/// an externally supplied digest.
public enum PerformanceControlProtocolContract {
    public static let maximumEncodedBytes = 8_192

    private static let canonicalUTF8 =
        #"{"authenticated_production_driver":false,"engine_contract":{"capabilities":["hotword_snapshot","local_asr","streaming"],"engine_id":"adapter_id@first16(artifact_content_sha256),or product@first16 when over 128 UTF-8 bytes","maximum_hotwords":{"maximum":128,"minimum":1},"network_policy":"offline"},"formats":{"artifact_generation":{"format":"lowercase_canonical_uuid"},"controlled_id":{"alphabet":"first ASCII alphanumeric; remainder ASCII alphanumeric, dot, hyphen, or underscore","maximum_utf8_bytes":128,"normalization":"NFC"},"load_ticket":{"alphabet":"lowercase_hex","encoded_utf8_bytes":64},"nonce":{"alphabet":"lowercase_hex","encoded_utf8_bytes":64},"sha256":{"alphabet":"lowercase_hex","encoded_utf8_bytes":64}},"frame":{"canonical_json":true,"carriage_return_allowed":false,"line_feed_allowed":false,"maximum_encoded_bytes":4096,"single_line_utf8":true,"unknown_keys_allowed":false},"id":"rimeai-performance-control-v2","messages":["#
        + #"{"directions":["collector_to_driver","collector_to_helper"],"exact_keys":["collector_nonce","peer_role","plan_nonce","schema_version","seq","session_id","type"],"fixed_values":{"schema_version":2,"seq":0},"nested_exact_keys":{},"peer_role_values":["driver","helper"],"type":"challenge"},"#
        + #"{"directions":["driver_to_collector"],"exact_keys":["collection_protocol","collector_nonce","driver_policy_sha256","measurement_policy_sha256","peer_nonce","plan_nonce","schema_version","seq","session_id","type"],"fixed_values":{"schema_version":2,"seq":0},"nested_exact_keys":{"collection_protocol":["id","sha256"]},"type":"driver_hello"},"#
        + #"{"directions":["helper_to_collector"],"exact_keys":["collector_nonce","engine_state","measurement_policy_sha256","peer_nonce","plan_nonce","release_policy_sha256","schema_version","seq","session_id","type"],"fixed_values":{"engine_state":"unloaded","schema_version":2,"seq":0},"nested_exact_keys":{},"type":"helper_hello"},"#
        + #"{"directions":["driver_to_collector"],"exact_keys":["schema_version","seq","session_id","trial","type"],"fixed_values":{"schema_version":2},"nested_exact_keys":{},"type":"arm_cold_load"},"#
        + #"{"directions":["collector_to_helper"],"exact_keys":["load_ticket","schema_version","seq","session_id","trial","type"],"fixed_values":{"schema_version":2},"nested_exact_keys":{},"type":"load_engine"},"#
        + #"{"directions":["helper_to_collector"],"exact_keys":["load_ticket","reply_to","schema_version","seq","session_id","trial","type"],"fixed_values":{"schema_version":2},"nested_exact_keys":{},"type":"load_started"},"#
        + #"{"directions":["collector_to_helper"],"exact_keys":["load_ticket","reply_to","schema_version","seq","session_id","trial","type"],"fixed_values":{"schema_version":2},"nested_exact_keys":{},"type":"load_started_ack"},"#
        + #"{"directions":["helper_to_collector"],"exact_keys":["engine","load_ticket","reply_to","schema_version","seq","session_id","trial","type"],"fixed_values":{"schema_version":2},"nested_exact_keys":{"engine":["adapter_id","artifact_content_sha256","artifact_generation","artifact_id","capabilities","engine_id","maximum_hotwords","network_policy"]},"type":"load_ready"}],"#
        + #""schema_version":2,"sequence":{"data_seq_minimum":1,"handshake_seq":0,"independent_directions":["collector_to_driver","collector_to_helper","driver_to_collector","helper_to_collector"],"next_data_seq":"previous_plus_one","reply_to":{"load_ready":"load_started_ack.seq","load_started":"load_engine.seq","load_started_ack":"load_started.seq"}},"session_binding":{"input":"SHA-256(domain || control_session_nonce_bytes || trial)","plan_nonce_domain":"rimeai.performance-control.plan.v1\u0000","session_id_domain":"rimeai.performance-control.session.v1\u0000","trial_encoding":"UInt64 big-endian"},"state_machine":{"failure":"terminal_on_any_protocol_error","failure_phase":"failed","subsequent_trial_restart":"helper_ready_to_handshaking","successful_trial_order":["handshaking","waiting_unloaded_helper","load_armed","load_started_acknowledged","loading","helper_ready"]},"trial":{"maximum":32,"minimum":1,"order":"strictly_ascending_from_one","session_binding":"derived_per_trial"}}"#

    public static let canonicalData: Data = {
        let data = Data(canonicalUTF8.utf8)
        precondition(data.count <= maximumEncodedBytes)
        precondition(!data.contains(0x0A) && !data.contains(0x0D))
        return data
    }()

    public static let identity: PerformanceControlProtocolIdentity = {
        let sha256 = SHA256.hash(data: canonicalData).map {
            String(format: "%02x", $0)
        }.joined()
        guard let identity = try? PerformanceControlProtocolIdentity(
            sha256: sha256
        ) else {
            preconditionFailure("code-owned control protocol digest is invalid")
        }
        return identity
    }()
}
