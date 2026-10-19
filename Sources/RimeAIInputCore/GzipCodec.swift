import Foundation
import zlib

/// Minimal gzip codec over the system zlib. The L2 user language model is
/// persisted as gzip-compressed JSON by the daemon; exporting it as part of
/// the language-profile export requires decoding on the Swift side.
public enum GzipCodec {
    public static func decode(_ data: Data) throws -> Data {
        try process(data, windowBits: 15 + 32, inflate: true)
    }

    /// Encodes standard gzip (deflate with a gzip wrapper), matching what
    /// Python's `gzip` module produces.
    public static func encode(_ data: Data) throws -> Data {
        try process(data, windowBits: 15 + 16, inflate: false)
    }

    private static func process(
        _ data: Data,
        windowBits: Int32,
        inflate: Bool
    ) throws -> Data {
        var stream = z_stream()
        let streamSize = Int32(MemoryLayout<z_stream>.stride)
        let initStatus: Int32 = data.withUnsafeBytes { _ in
            if inflate {
                return inflateInit2_(
                    &stream, windowBits, ZLIB_VERSION, streamSize
                )
            }
            return deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                windowBits,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                streamSize
            )
        }
        guard initStatus == Z_OK else {
            throw GzipError.streamFailure(status: initStatus)
        }
        defer {
            if inflate {
                inflateEnd(&stream)
            } else {
                deflateEnd(&stream)
            }
        }
        return try data.withUnsafeBytes { inputBuffer in
            guard let inputAddress = inputBuffer.baseAddress else {
                return Data()
            }
            stream.next_in = UnsafeMutablePointer<UInt8>(
                mutating: inputAddress.assumingMemoryBound(to: UInt8.self)
            )
            stream.avail_in = UInt32(inputBuffer.count)
            var output = Data()
            let chunk = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(
                capacity: chunk
            )
            defer { buffer.deallocate() }
            while true {
                stream.next_out = buffer
                stream.avail_out = UInt32(chunk)
                let status: Int32
                if inflate {
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                } else {
                    status = deflate(&stream, Z_FINISH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
                let okStatus = inflate
                    ? status == Z_OK || status == Z_BUF_ERROR
                    : status == Z_OK
                guard okStatus else {
                    throw GzipError.streamFailure(status: status)
                }
                if produced == 0, stream.avail_in == 0, inflate {
                    throw GzipError.truncated
                }
            }
            return output
        }
    }
}

public enum GzipError: Error, Equatable {
    case streamFailure(status: Int32)
    case truncated
}
