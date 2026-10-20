import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("gzip codec (language-profile export)")
struct GzipCodecTests {
    @Test("decode reads a Python-gzip fixture byte for byte")
    func decodesPythonFixture() throws {
        // Produced by gzip.compress(JSON, mtime=0) in Python 3.12.
        let fixture: [UInt8] = [
            31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 171, 86, 202, 72, 205, 201,
            201, 87, 178, 82, 80, 122, 178, 99, 218, 243, 169, 61, 74,
            181, 0, 187, 22, 199, 125, 19, 0, 0, 0,
        ]
        let decoded = try GzipCodec.decode(Data(fixture))
        let text = String(decoding: decoded, as: UTF8.self)
        #expect(text == "{\"hello\": \"世界\"}")
    }

    @Test("decode reads the Swift-encoded fixture the daemon also reads")
    func decodesSwiftEncodedFixture() throws {
        // 由固件 GzipCodec.encode 产出的字节（同一份固件也由
        // tests/test_user_lm.py 用 Python gzip 解码）：两侧共享一份
        // 字节固件，Swift 写 → daemon 读的兼容性因此是被测事实。
        let fixture: [UInt8] = [
            31, 139, 8, 0, 0, 0, 0, 0, 0, 19, 21, 204, 75, 10, 128, 32,
            20, 70, 225, 189, 252, 99, 29, 20, 141, 220, 140, 220, 244,
            162, 130, 143, 80, 11, 66, 220, 123, 57, 59, 131, 143, 51,
            208, 140, 231, 68, 250, 225, 218, 66, 201, 80, 155, 64, 42,
            150, 163, 238, 239, 197, 80, 184, 27, 87, 105, 60, 85, 153,
            93, 165, 4, 1, 91, 18, 133, 220, 160, 6, 92, 44, 39, 197,
            85, 75, 144, 233, 255, 5, 234, 216, 231, 156, 31, 13, 16,
            108, 70, 90, 0, 0, 0,
        ]
        let decoded = try GzipCodec.decode(Data(fixture))
        let text = String(decoding: decoded, as: UTF8.self)
        #expect(
            text
                == #"{"schema_version":1,"model_type":"user-char-ngram","domains":{"global":{"characters":42}}}"#
        )
    }

    @Test("encode/decode round-trips arbitrary payloads")
    func roundTrip() throws {
        let original = Data(repeating: 0x61, count: 200_000) + Data(
            "语言画像".utf8
        )
        let decoded = try GzipCodec.decode(GzipCodec.encode(original))
        #expect(decoded == original)
    }

    @Test("decode rejects truncated input")
    func rejectsTruncated() {
        let fixture = Data([31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 171])
        #expect(throws: (any Error).self) {
            _ = try GzipCodec.decode(fixture)
        }
    }
}
