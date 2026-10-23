//
//  HTTPHookGzip.swift
//  MudmouthHTTPHooks
//
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation
import zlib

/// Strict, bounded gzip decoding for observation only. Anything but exactly one complete, valid member
/// that inflates within the cap (CRC32 and ISIZE verified, no trailing bytes) is rejected.
enum HTTPHookGzip {
    /// windowBits 31: gzip wrapper only, never raw deflate or zlib streams.
    private static let gzipWindowBits: Int32 = 15 + 16

    static func decode(_ input: Data, maxOutput: Int) -> Data? {
        guard maxOutput >= 0, maxOutput < Int(Int32.max), !input.isEmpty, input.count <= Int(UInt32.max) else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, gzipWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var source = [UInt8](input)
        // One byte beyond the cap proves an overrun without ever allocating more than cap + 1.
        var output = [UInt8](repeating: 0, count: maxOutput + 1)
        let outputSize = output.count
        let status: Int32 = source.withUnsafeMutableBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                stream.next_in = src.baseAddress
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(outputSize)
                // A single Z_FINISH call either completes the member within the buffer or fails; no loop to stall.
                return inflate(&stream, Z_FINISH)
            }
        }
        let produced = Int(stream.total_out)
        guard status == Z_STREAM_END, stream.avail_in == 0, produced <= maxOutput else { return nil }
        return Data(output.prefix(produced))
    }
}
