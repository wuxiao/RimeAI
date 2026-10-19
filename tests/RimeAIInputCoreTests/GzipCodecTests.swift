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
