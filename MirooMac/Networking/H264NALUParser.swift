//
//  H264NALUParser.swift
//  Miroo
//
//  Phase 5: High-performance H.264 Annex-B NAL unit parser and AVCC converter.
//  Extracts SPS, PPS, IDR, and non-IDR slices, replacing Annex-B start codes
//  with 4-byte big-endian length prefixes required by VideoToolbox.
//

import Foundation

public struct ParsedNALUResult {
    public let sps: Data?
    public let pps: Data?
    public let avccData: Data
    public let hasKeyframe: Bool
    public let hasSlice: Bool
    public let naluCount: Int

    public init(
        sps: Data? = nil,
        pps: Data? = nil,
        avccData: Data = Data(),
        hasKeyframe: Bool = false,
        hasSlice: Bool = false,
        naluCount: Int = 0
    ) {
        self.sps = sps
        self.pps = pps
        self.avccData = avccData
        self.hasKeyframe = hasKeyframe
        self.hasSlice = hasSlice
        self.naluCount = naluCount
    }
}

public enum H264NALUParser {

    /// Parses an Annex-B data buffer, extracting parameter sets (SPS/PPS) and building AVCC data for slices.
    public static func parse(annexBData: Data) -> ParsedNALUResult {
        guard annexBData.count >= 4 else {
            return ParsedNALUResult()
        }

        var sps: Data?
        var pps: Data?
        var avccData = Data(capacity: annexBData.count)
        var hasKeyframe = false
        var hasSlice = false
        var naluCount = 0

        // Find all start codes (0x000001 or 0x00000001)
        struct NALULocation {
            let offset: Int
            let length: Int
        }

        var naluLocations: [NALULocation] = []

        annexBData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = rawBuffer.count

            var i = 0
            var lastStart = -1

            while i < count - 2 {
                // Check for 0x00 0x00 0x01
                if ptr[i] == 0 && ptr[i + 1] == 0 && ptr[i + 2] == 1 {
                    let startCodeLen = (i > 0 && ptr[i - 1] == 0) ? 4 : 3
                    let naluStart = i + 3

                    if lastStart != -1 {
                        let prevStartCodeLen = (lastStart >= 4 && ptr[lastStart - 4] == 0) ? 4 : 3
                        let prevNALUOffset = (prevStartCodeLen == 4) ? lastStart : (lastStart + 1)
                        let prevNALUEnd = (startCodeLen == 4) ? (i - 1) : i
                        if prevNALUEnd > prevNALUOffset {
                            naluLocations.append(NALULocation(offset: prevNALUOffset, length: prevNALUEnd - prevNALUOffset))
                        }
                    }

                    lastStart = naluStart
                    i += 3
                } else {
                    i += 1
                }
            }

            // Append final NALU
            if lastStart != -1 && lastStart < count {
                let prevStartCodeLen = (lastStart >= 4 && ptr[lastStart - 4] == 0) ? 4 : 3
                let prevNALUOffset = (prevStartCodeLen == 4) ? lastStart : (lastStart + 1)
                if count > prevNALUOffset {
                    naluLocations.append(NALULocation(offset: prevNALUOffset, length: count - prevNALUOffset))
                }
            }
        }

        // Process each extracted NAL unit
        for loc in naluLocations {
            guard loc.length > 0, loc.offset + loc.length <= annexBData.count else { continue }
            let nalu = annexBData.subdata(in: loc.offset..<(loc.offset + loc.length))
            let naluType = nalu[0] & 0x1F
            naluCount += 1

            switch naluType {
            case 7: // SPS
                sps = nalu
            case 8: // PPS
                pps = nalu
            case 5: // IDR Slice (Keyframe)
                hasKeyframe = true
                hasSlice = true
                appendAVCC(nalu: nalu, to: &avccData)
            case 1: // Non-IDR Slice (P-frame)
                hasSlice = true
                appendAVCC(nalu: nalu, to: &avccData)
            case 6: // SEI (Supplemental Enhancement Information)
                appendAVCC(nalu: nalu, to: &avccData)
            default:
                // Other NALUs (e.g. AUD) can be forwarded if needed
                if naluType < 32 {
                    appendAVCC(nalu: nalu, to: &avccData)
                }
            }
        }

        return ParsedNALUResult(
            sps: sps,
            pps: pps,
            avccData: avccData,
            hasKeyframe: hasKeyframe,
            hasSlice: hasSlice,
            naluCount: naluCount
        )
    }

    /// Appends a NAL unit to the AVCC buffer with a 4-byte big-endian length header.
    @inline(__always)
    private static func appendAVCC(nalu: Data, to buffer: inout Data) {
        var length = UInt32(nalu.count).bigEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }
        buffer.append(nalu)
    }
}
