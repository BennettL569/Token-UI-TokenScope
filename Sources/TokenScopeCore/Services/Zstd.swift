import Foundation

/// A self-contained Zstandard decoder (RFC 8878): decompression only, no dictionaries.
///
/// DeepSeek Harness stores each session log as a concatenation of independent zstd frames, and macOS
/// ships no zstd codec — neither Apple's Compression framework nor the system libarchive supports it —
/// so TokenScope decodes the format itself instead of linking a Homebrew library or vendoring a C
/// target (which the Xcode project would also have to build).
///
/// The decoder is written for untrusted input: every read is bounds-checked and a malformed frame
/// throws instead of trapping. A frame that simply ends early — one still being appended, or a torn
/// tail left by a crash — throws `.truncated`, so a log reader can stop at the last complete frame
/// and resume there later. It follows the structure of the reference "educational decoder" in the
/// zstd repository, and verifies the optional XXH64 content checksum.
public enum Zstd {
    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        /// The input ended inside a frame.
        case truncated
        /// The frame is malformed: bad magic, reserved bits, an impossible table, a checksum mismatch…
        case corrupt(String)
        /// A valid feature this decoder doesn't implement (dictionaries).
        case unsupported(String)

        public var description: String {
            switch self {
            case .truncated: return "zstd: truncated frame"
            case .corrupt(let reason): return "zstd: corrupt frame (\(reason))"
            case .unsupported(let reason): return "zstd: unsupported (\(reason))"
            }
        }
    }

    /// One frame found at a byte offset: its decoded content (`nil` for a skippable frame) and the
    /// offset just past it.
    public struct Frame: Equatable, Sendable {
        public var content: [UInt8]?
        public var end: Int
    }

    public static let frameMagic: UInt32 = 0xFD2F_B528

    /// Largest content a single frame may decode to. A guard against decompression bombs — DeepSeek
    /// Harness writes one small frame per append batch, so real frames are far below this.
    public static let maxFrameContentSize = 1 << 30

    /// Decodes the frame that starts at `offset`.
    public static func decodeFrame(_ input: [UInt8], at offset: Int) throws -> Frame {
        try input.withUnsafeBufferPointer { buffer in
            var reader = FrameReader(input: buffer, position: offset)
            return try reader.decodeFrame()
        }
    }

    /// Decodes a whole buffer of concatenated frames. Unlike `decodeFrame`, an incomplete final frame
    /// is an error here (`.truncated`), so this is for complete files.
    public static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let frame = try decodeFrame(input, at: offset)
            if let content = frame.content { output.append(contentsOf: content) }
            offset = frame.end
        }
        return output
    }

    public static func decompress(_ data: Data) throws -> Data {
        Data(try decompress([UInt8](data)))
    }

    /// Whether `input` starts a zstd or skippable frame at `offset` (a cheap magic-number check).
    public static func hasFrameMagic(_ input: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= input.count else { return false }
        let magic = UInt32(input[offset]) | UInt32(input[offset + 1]) << 8 | UInt32(input[offset + 2]) << 16 | UInt32(input[offset + 3]) << 24
        return magic == frameMagic || magic & 0xFFFF_FFF0 == 0x184D_2A50
    }
}

// MARK: - Frame

private struct FrameReader {
    let input: UnsafeBufferPointer<UInt8>
    var position: Int

    // Per-frame decoding state shared across blocks.
    var output: [UInt8] = []
    var repeatOffsets: (Int, Int, Int) = (1, 4, 8)
    var huffman: HuffmanTable?
    var literalLengthTable: FSETable?
    var offsetTable: FSETable?
    var matchLengthTable: FSETable?

    init(input: UnsafeBufferPointer<UInt8>, position: Int) {
        self.input = input
        self.position = position
    }

    mutating func byte() throws -> UInt8 {
        guard position >= 0, position < input.count else { throw Zstd.DecodeError.truncated }
        defer { position += 1 }
        return input[position]
    }

    mutating func littleEndian(_ count: Int) throws -> UInt64 {
        guard position >= 0, count <= input.count - position else { throw Zstd.DecodeError.truncated }
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(input[position + index]) << (8 * UInt64(index)) }
        position += count
        return value
    }

    mutating func decodeFrame() throws -> Zstd.Frame {
        let magic = UInt32(try littleEndian(4))
        if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            // Skippable frame: a 4-byte size, then that many bytes of user data.
            let size = Int(try littleEndian(4))
            guard size <= input.count - position else { throw Zstd.DecodeError.truncated }
            position += size
            return Zstd.Frame(content: nil, end: position)
        }
        guard magic == Zstd.frameMagic else { throw Zstd.DecodeError.corrupt("bad magic number") }

        let descriptor = try byte()
        let contentSizeFlag = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        let hasChecksum = descriptor & 0x04 != 0
        let dictionaryIdFlag = Int(descriptor & 0x03)
        guard descriptor & 0x08 == 0 else { throw Zstd.DecodeError.corrupt("reserved frame header bit set") }

        if !singleSegment {
            // Window descriptor: only bounds back-references, which are checked against the
            // decoded output instead, so the value itself is not needed.
            _ = try byte()
        }
        let dictionaryIdSize = [0, 1, 2, 4][dictionaryIdFlag]
        let dictionaryId = try littleEndian(dictionaryIdSize)
        guard dictionaryId == 0 else { throw Zstd.DecodeError.unsupported("dictionary \(dictionaryId)") }

        var contentSize: UInt64?
        switch contentSizeFlag {
        case 0: contentSize = singleSegment ? try littleEndian(1) : nil
        case 1: contentSize = try littleEndian(2) + 256
        case 2: contentSize = try littleEndian(4)
        default: contentSize = try littleEndian(8)
        }
        if let contentSize, contentSize > UInt64(Zstd.maxFrameContentSize) {
            throw Zstd.DecodeError.unsupported("frame content too large")
        }
        if let contentSize { output.reserveCapacity(Int(contentSize)) }

        while true {
            let header = Int(try littleEndian(3))
            let isLast = header & 1 != 0
            let blockType = (header >> 1) & 3
            let blockSize = header >> 3
            guard blockSize <= maxBlockSize else { throw Zstd.DecodeError.corrupt("block larger than 128 KiB") }
            switch blockType {
            case 0: // Raw
                guard blockSize <= input.count - position else { throw Zstd.DecodeError.truncated }
                output.append(contentsOf: UnsafeBufferPointer(rebasing: input[position..<(position + blockSize)]))
                position += blockSize
            case 1: // RLE: one byte, repeated blockSize times
                let value = try byte()
                output.append(contentsOf: repeatElement(value, count: blockSize))
            case 2: // Compressed
                guard blockSize <= input.count - position else { throw Zstd.DecodeError.truncated }
                let block = position..<(position + blockSize)
                position += blockSize
                try decodeCompressedBlock(block)
            default:
                throw Zstd.DecodeError.corrupt("reserved block type")
            }
            guard output.count <= Zstd.maxFrameContentSize else { throw Zstd.DecodeError.unsupported("frame content too large") }
            if isLast { break }
        }

        if let contentSize, UInt64(output.count) != contentSize {
            throw Zstd.DecodeError.corrupt("content size mismatch")
        }
        if hasChecksum {
            let stored = UInt32(try littleEndian(4))
            let computed = UInt32(truncatingIfNeeded: XXH64.hash(output))
            guard stored == computed else { throw Zstd.DecodeError.corrupt("checksum mismatch") }
        }
        return Zstd.Frame(content: output, end: position)
    }

    // MARK: Compressed block

    mutating func decodeCompressedBlock(_ block: Range<Int>) throws {
        // Every failure inside a complete block is corruption: the block's bytes are all present.
        var cursor = block.lowerBound
        let literals = try decodeLiterals(block, cursor: &cursor)
        try decodeAndExecuteSequences(cursor..<block.upperBound, literals: literals)
    }

    private func corruptIfShort(_ needed: Int, _ cursor: Int, _ end: Int, _ what: String) throws {
        guard needed >= 0, needed <= end - cursor else { throw Zstd.DecodeError.corrupt(what) }
    }

    mutating func decodeLiterals(_ block: Range<Int>, cursor: inout Int) throws -> [UInt8] {
        let end = block.upperBound
        try corruptIfShort(1, cursor, end, "missing literals header")
        let b0 = Int(input[cursor])
        let literalsType = b0 & 3
        let sizeFormat = (b0 >> 2) & 3

        if literalsType == 0 || literalsType == 1 {
            // Raw or RLE literals.
            let regenerated: Int
            switch sizeFormat {
            case 0, 2:
                regenerated = b0 >> 3
                cursor += 1
            case 1:
                try corruptIfShort(2, cursor, end, "short literals header")
                regenerated = (b0 >> 4) + (Int(input[cursor + 1]) << 4)
                cursor += 2
            default:
                try corruptIfShort(3, cursor, end, "short literals header")
                regenerated = (b0 >> 4) + (Int(input[cursor + 1]) << 4) + (Int(input[cursor + 2]) << 12)
                cursor += 3
            }
            guard regenerated <= maxBlockSize else { throw Zstd.DecodeError.corrupt("literals too large") }
            if literalsType == 0 {
                try corruptIfShort(regenerated, cursor, end, "raw literals overrun the block")
                let literals = Array(UnsafeBufferPointer(rebasing: input[cursor..<(cursor + regenerated)]))
                cursor += regenerated
                return literals
            }
            try corruptIfShort(1, cursor, end, "missing RLE literal")
            let value = input[cursor]
            cursor += 1
            return [UInt8](repeating: value, count: regenerated)
        }

        // Huffman-compressed (2) or treeless (3, reusing the previous table) literals.
        let headerSize = sizeFormat <= 1 ? 3 : sizeFormat == 2 ? 4 : 5
        try corruptIfShort(headerSize, cursor, end, "short literals header")
        var combined: UInt64 = 0
        for index in 0..<headerSize { combined |= UInt64(input[cursor + index]) << (8 * UInt64(index)) }
        cursor += headerSize
        let regenerated: Int
        let compressed: Int
        switch sizeFormat {
        case 0, 1:
            regenerated = Int((combined >> 4) & 0x3FF)
            compressed = Int((combined >> 14) & 0x3FF)
        case 2:
            regenerated = Int((combined >> 4) & 0x3FFF)
            compressed = Int((combined >> 18) & 0x3FFF)
        default:
            regenerated = Int((combined >> 4) & 0x3FFFF)
            compressed = Int((combined >> 22) & 0x3FFFF)
        }
        guard regenerated <= maxBlockSize else { throw Zstd.DecodeError.corrupt("literals too large") }
        try corruptIfShort(compressed, cursor, end, "compressed literals overrun the block")
        let streamsEnd = cursor + compressed
        var streamsStart = cursor
        cursor = streamsEnd

        if literalsType == 2 {
            huffman = try HuffmanTable.read(input, range: streamsStart..<streamsEnd, consumed: &streamsStart)
        }
        guard let table = huffman else { throw Zstd.DecodeError.corrupt("treeless literals without a previous Huffman table") }

        var literals = [UInt8]()
        literals.reserveCapacity(regenerated)
        if sizeFormat == 0 {
            try table.decodeStream(input, range: streamsStart..<streamsEnd, into: &literals, limit: regenerated)
        } else {
            // Four streams, preceded by a 6-byte jump table holding the first three sizes.
            try corruptIfShort(6, streamsStart, streamsEnd, "missing jump table")
            let size1 = Int(input[streamsStart]) | Int(input[streamsStart + 1]) << 8
            let size2 = Int(input[streamsStart + 2]) | Int(input[streamsStart + 3]) << 8
            let size3 = Int(input[streamsStart + 4]) | Int(input[streamsStart + 5]) << 8
            var start = streamsStart + 6
            let size4 = streamsEnd - start - size1 - size2 - size3
            guard size4 >= 1 else { throw Zstd.DecodeError.corrupt("bad jump table") }
            let perStream = (regenerated + 3) / 4
            for (index, size) in [size1, size2, size3, size4].enumerated() {
                let expected = index < 3 ? perStream : regenerated - 3 * perStream
                guard expected >= 0 else { throw Zstd.DecodeError.corrupt("bad literal stream split") }
                let before = literals.count
                try table.decodeStream(input, range: start..<(start + size), into: &literals, limit: before + expected)
                guard literals.count - before == expected else { throw Zstd.DecodeError.corrupt("literal stream size mismatch") }
                start += size
            }
        }
        guard literals.count == regenerated else { throw Zstd.DecodeError.corrupt("literals size mismatch") }
        return literals
    }

    // MARK: Sequences

    mutating func decodeAndExecuteSequences(_ section: Range<Int>, literals: [UInt8]) throws {
        let end = section.upperBound
        var cursor = section.lowerBound
        try corruptIfShort(1, cursor, end, "missing sequences header")
        let b0 = Int(input[cursor])
        var sequenceCount: Int
        if b0 == 0 {
            // No sequences: the block is its literals.
            output.append(contentsOf: literals)
            return
        } else if b0 < 128 {
            sequenceCount = b0
            cursor += 1
        } else if b0 < 255 {
            try corruptIfShort(2, cursor, end, "short sequences header")
            sequenceCount = ((b0 - 128) << 8) + Int(input[cursor + 1])
            cursor += 2
        } else {
            try corruptIfShort(3, cursor, end, "short sequences header")
            sequenceCount = Int(input[cursor + 1]) + (Int(input[cursor + 2]) << 8) + 0x7F00
            cursor += 3
        }
        try corruptIfShort(1, cursor, end, "missing compression modes")
        let modes = Int(input[cursor])
        cursor += 1
        guard modes & 3 == 0 else { throw Zstd.DecodeError.corrupt("reserved compression mode bits set") }

        literalLengthTable = try FSETable.select(mode: (modes >> 6) & 3, kind: .literalLength, previous: literalLengthTable, input: input, cursor: &cursor, end: end)
        offsetTable = try FSETable.select(mode: (modes >> 4) & 3, kind: .offset, previous: offsetTable, input: input, cursor: &cursor, end: end)
        matchLengthTable = try FSETable.select(mode: (modes >> 2) & 3, kind: .matchLength, previous: matchLengthTable, input: input, cursor: &cursor, end: end)
        guard let llTable = literalLengthTable, let ofTable = offsetTable, let mlTable = matchLengthTable else {
            throw Zstd.DecodeError.corrupt("missing sequence tables")
        }

        var bits = try BackwardBits(input, range: cursor..<end)
        var llState = Int(bits.read(llTable.accuracyLog))
        var ofState = Int(bits.read(ofTable.accuracyLog))
        var mlState = Int(bits.read(mlTable.accuracyLog))

        var literalCursor = 0
        while sequenceCount > 0 {
            sequenceCount -= 1
            let ofCode = Int(ofTable.symbols[ofState])
            let llCode = Int(llTable.symbols[llState])
            let mlCode = Int(mlTable.symbols[mlState])
            guard llCode < literalLengthBaselines.count, mlCode < matchLengthBaselines.count, ofCode <= 31 else {
                throw Zstd.DecodeError.corrupt("sequence code out of range")
            }
            // Extra bits are read offset, then match length, then literal length.
            let offsetValue = (1 << ofCode) + Int(bits.read(ofCode))
            let matchLength = matchLengthBaselines[mlCode] + Int(bits.read(matchLengthExtraBits[mlCode]))
            let literalLength = literalLengthBaselines[llCode] + Int(bits.read(literalLengthExtraBits[llCode]))
            if sequenceCount > 0 {
                // States update in literal-length, match-length, offset order.
                llState = llTable.nextState(llState, bits.read(Int(llTable.bitCounts[llState])))
                mlState = mlTable.nextState(mlState, bits.read(Int(mlTable.bitCounts[mlState])))
                ofState = ofTable.nextState(ofState, bits.read(Int(ofTable.bitCounts[ofState])))
            }

            let offset = try resolveOffset(offsetValue, literalLength: literalLength)

            guard literalLength <= literals.count - literalCursor else { throw Zstd.DecodeError.corrupt("literal length overruns literals") }
            output.append(contentsOf: literals[literalCursor..<(literalCursor + literalLength)])
            literalCursor += literalLength

            guard offset >= 1, offset <= output.count else { throw Zstd.DecodeError.corrupt("match offset out of range") }
            guard matchLength <= Zstd.maxFrameContentSize - output.count else { throw Zstd.DecodeError.unsupported("frame content too large") }
            var source = output.count - offset
            if offset >= matchLength, matchLength >= 16 {
                // Copy through a temporary: appending a slice of `output` to `output` itself would
                // force a copy-on-write of the whole buffer on every match (quadratic).
                let chunk = Array(output[source..<(source + matchLength)])
                output.append(contentsOf: chunk)
            } else {
                // Short or overlapping copy: byte by byte, so a match can repeat its own output.
                for _ in 0..<matchLength {
                    output.append(output[source])
                    source += 1
                }
            }
        }
        guard bits.isExhausted else { throw Zstd.DecodeError.corrupt("sequence bitstream not fully consumed") }
        output.append(contentsOf: literals[literalCursor...])
    }

    /// Applies the repeat-offset rules (RFC 8878 §3.1.2.5) and updates the history.
    mutating func resolveOffset(_ value: Int, literalLength: Int) throws -> Int {
        var (first, second, third) = repeatOffsets
        let offset: Int
        if value > 3 {
            offset = value - 3
            third = second
            second = first
            first = offset
        } else {
            // With no literals, repeat offsets shift by one: 1 → second, 2 → third, 3 → first − 1.
            let index = value - 1 + (literalLength == 0 ? 1 : 0)
            switch index {
            case 0:
                offset = first
            case 1:
                offset = second
                second = first
                first = offset
            case 2:
                offset = third
                third = second
                second = first
                first = offset
            default:
                offset = first - 1
                third = second
                second = first
                first = offset
            }
        }
        guard offset >= 1 else { throw Zstd.DecodeError.corrupt("zero offset") }
        repeatOffsets = (first, second, third)
        return offset
    }
}

private let maxBlockSize = 128 * 1024

private let literalLengthBaselines: [Int] = Array(0...15) + [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
private let literalLengthExtraBits: [Int] = Array(repeating: 0, count: 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
private let matchLengthBaselines: [Int] = Array(3...34) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
private let matchLengthExtraBits: [Int] = Array(repeating: 0, count: 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

/// Index of the highest set bit (floor(log2(value))); `value` must be positive.
@inline(__always) private func highestBit(_ value: Int) -> Int {
    Int.bitWidth - 1 - value.leadingZeroBitCount
}

// MARK: - Bit streams

/// A bitstream read backwards from its end, as zstd's Huffman, FSE and sequence streams are. The
/// final byte carries a 1-bit end marker above the padding. Reading past the start yields zero bits,
/// which the spec relies on; `position` going negative records how far past the start reads went.
private struct BackwardBits {
    let input: UnsafeBufferPointer<UInt8>
    let start: Int
    private(set) var position: Int

    init(_ input: UnsafeBufferPointer<UInt8>, range: Range<Int>) throws {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= input.count else {
            throw Zstd.DecodeError.corrupt("empty bitstream")
        }
        let last = input[range.upperBound - 1]
        guard last != 0 else { throw Zstd.DecodeError.corrupt("bitstream end marker missing") }
        self.input = input
        self.start = range.lowerBound
        self.position = range.count * 8 - (8 - highestBit(Int(last)))
    }

    var isExhausted: Bool { position == 0 }

    mutating func read(_ count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        position -= count
        var bitOffset = position
        var available = count
        if bitOffset < 0 {
            available += bitOffset
            bitOffset = 0
        }
        var value: UInt64 = 0
        if available > 0 {
            var got = 0
            var at = bitOffset
            while got < available {
                let byte = UInt64(input[start + (at >> 3)])
                let shift = at & 7
                let take = min(8 - shift, available - got)
                value |= ((byte >> UInt64(shift)) & ((1 << UInt64(take)) - 1)) << UInt64(got)
                got += take
                at += take
            }
        }
        if position < 0 {
            // Bits from before the start of the stream read as zero, below the real ones.
            let missing = -position
            value = missing >= 64 ? 0 : value << UInt64(missing)
        }
        return value
    }
}

/// Little-endian bits read forwards, for FSE table descriptions. Running off the end is corruption:
/// the description lives inside a block whose bytes are all present.
private struct ForwardBits {
    let input: UnsafeBufferPointer<UInt8>
    let range: Range<Int>
    var bitOffset = 0

    mutating func peek(_ count: Int) throws -> Int {
        var value = 0
        var got = 0
        var at = bitOffset
        while got < count {
            let index = range.lowerBound + (at >> 3)
            guard index < range.upperBound else { throw Zstd.DecodeError.corrupt("table description overruns its block") }
            let shift = at & 7
            let take = min(8 - shift, count - got)
            value |= ((Int(input[index]) >> shift) & ((1 << take) - 1)) << got
            got += take
            at += take
        }
        return value
    }

    mutating func skip(_ count: Int) { bitOffset += count }

    var bytesConsumed: Int { (bitOffset + 7) / 8 }
}

// MARK: - FSE

private struct FSETable {
    enum Kind {
        case literalLength, offset, matchLength

        var maxAccuracyLog: Int {
            switch self {
            case .literalLength, .matchLength: return 9
            case .offset: return 8
            }
        }

        var maxSymbol: Int {
            switch self {
            case .literalLength: return 35
            case .matchLength: return 52
            case .offset: return 31
            }
        }

        var predefined: FSETable {
            switch self {
            case .literalLength: return predefinedLiteralLength
            case .matchLength: return predefinedMatchLength
            case .offset: return predefinedOffset
            }
        }
    }

    var accuracyLog: Int
    var symbols: [UInt8]
    var bitCounts: [UInt8]
    var baselines: [Int]

    @inline(__always) func nextState(_ state: Int, _ bits: UInt64) -> Int {
        baselines[state] + Int(bits)
    }

    static func rle(_ symbol: UInt8) -> FSETable {
        FSETable(accuracyLog: 0, symbols: [symbol], bitCounts: [0], baselines: [0])
    }

    /// Builds the decoding table for normalized counts (`-1` = "less than one").
    static func build(counts: [Int], accuracyLog: Int) throws -> FSETable {
        let size = 1 << accuracyLog
        var symbols = [UInt8](repeating: 0, count: size)
        var next = [Int](repeating: 0, count: counts.count)
        // "Less than one" symbols take single cells from the top of the table.
        var highThreshold = size
        for (symbol, count) in counts.enumerated() where count == -1 {
            highThreshold -= 1
            guard highThreshold >= 0 else { throw Zstd.DecodeError.corrupt("FSE table overfull") }
            symbols[highThreshold] = UInt8(symbol)
            next[symbol] = 1
        }
        // The rest are spread over the table with a fixed step that visits every cell once.
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var position = 0
        for (symbol, count) in counts.enumerated() where count > 0 {
            next[symbol] = count
            for _ in 0..<count {
                symbols[position] = UInt8(symbol)
                repeat {
                    position = (position + step) & mask
                } while position >= highThreshold
            }
        }
        guard position == 0 else { throw Zstd.DecodeError.corrupt("FSE table not filled exactly") }
        var bitCounts = [UInt8](repeating: 0, count: size)
        var baselines = [Int](repeating: 0, count: size)
        for state in 0..<size {
            let symbol = Int(symbols[state])
            let descriptor = next[symbol]
            next[symbol] += 1
            guard descriptor > 0 else { throw Zstd.DecodeError.corrupt("FSE state without a symbol") }
            let bits = accuracyLog - highestBit(descriptor)
            guard bits >= 0 else { throw Zstd.DecodeError.corrupt("FSE table overfull") }
            bitCounts[state] = UInt8(bits)
            baselines[state] = (descriptor << bits) - size
        }
        return FSETable(accuracyLog: accuracyLog, symbols: symbols, bitCounts: bitCounts, baselines: baselines)
    }

    /// Reads an FSE table description (RFC 8878 §4.1.1) from `input` at `cursor`, advancing it.
    static func read(_ input: UnsafeBufferPointer<UInt8>, cursor: inout Int, end: Int, maxAccuracyLog: Int, maxSymbol: Int) throws -> FSETable {
        var bits = ForwardBits(input: input, range: cursor..<end)
        let accuracyLog = try bits.peek(4) + 5
        bits.skip(4)
        guard accuracyLog <= maxAccuracyLog else { throw Zstd.DecodeError.corrupt("FSE accuracy too large") }
        var remaining = 1 << accuracyLog
        var counts: [Int] = []
        while remaining > 0 {
            guard counts.count <= maxSymbol else { throw Zstd.DecodeError.corrupt("too many FSE symbols") }
            let width = highestBit(remaining + 1) + 1
            var value = try bits.peek(width)
            let lowerMask = (1 << (width - 1)) - 1
            let threshold = (1 << width) - 1 - (remaining + 1)
            if value & lowerMask < threshold {
                value &= lowerMask
                bits.skip(width - 1)
            } else {
                if value > lowerMask { value -= threshold }
                bits.skip(width)
            }
            let probability = value - 1
            remaining -= abs(probability)
            counts.append(probability)
            if probability == 0 {
                // A zero is followed by 2-bit repeat flags for further zeros; 3 means "and more".
                while true {
                    let repeatCount = try bits.peek(2)
                    bits.skip(2)
                    for _ in 0..<repeatCount { counts.append(0) }
                    guard counts.count <= maxSymbol + 1 else { throw Zstd.DecodeError.corrupt("too many FSE symbols") }
                    if repeatCount != 3 { break }
                }
            }
        }
        guard remaining == 0 else { throw Zstd.DecodeError.corrupt("FSE probabilities overshoot") }
        guard counts.count <= maxSymbol + 1 else { throw Zstd.DecodeError.corrupt("too many FSE symbols") }
        cursor += bits.bytesConsumed
        guard cursor <= end else { throw Zstd.DecodeError.corrupt("FSE description overruns its block") }
        return try build(counts: counts, accuracyLog: accuracyLog)
    }

    /// Picks the table for one sequence field per its compression mode.
    static func select(mode: Int, kind: Kind, previous: FSETable?, input: UnsafeBufferPointer<UInt8>, cursor: inout Int, end: Int) throws -> FSETable {
        switch mode {
        case 0:
            return kind.predefined
        case 1:
            guard cursor < end else { throw Zstd.DecodeError.corrupt("missing RLE symbol") }
            let symbol = input[cursor]
            cursor += 1
            guard Int(symbol) <= kind.maxSymbol else { throw Zstd.DecodeError.corrupt("RLE symbol out of range") }
            return .rle(symbol)
        case 2:
            return try read(input, cursor: &cursor, end: end, maxAccuracyLog: kind.maxAccuracyLog, maxSymbol: kind.maxSymbol)
        default:
            guard let previous else { throw Zstd.DecodeError.corrupt("repeat mode without a previous table") }
            return previous
        }
    }
}

// The default distributions (RFC 8878 §3.1.1.3.2.2). Built once; they are valid by construction.
private let predefinedLiteralLength = try! FSETable.build(counts: [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], accuracyLog: 6)
private let predefinedMatchLength = try! FSETable.build(counts: [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1], accuracyLog: 6)
private let predefinedOffset = try! FSETable.build(counts: [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1], accuracyLog: 5)

// MARK: - Huffman

private struct HuffmanTable {
    var maxBits: Int
    var symbols: [UInt8]
    var bitCounts: [UInt8]

    /// Reads a Huffman tree description (RFC 8878 §4.2.1) at the start of `range`; `consumed` is
    /// set to the first byte after it.
    static func read(_ input: UnsafeBufferPointer<UInt8>, range: Range<Int>, consumed: inout Int) throws -> HuffmanTable {
        guard !range.isEmpty else { throw Zstd.DecodeError.corrupt("missing Huffman description") }
        let header = Int(input[range.lowerBound])
        var cursor = range.lowerBound + 1
        var weights: [Int] = []
        if header >= 128 {
            // Direct representation: 4-bit weights, two per byte, high nibble first.
            let count = header - 127
            let byteCount = (count + 1) / 2
            guard byteCount <= range.upperBound - cursor else { throw Zstd.DecodeError.corrupt("Huffman weights overrun the block") }
            for index in 0..<count {
                let byte = Int(input[cursor + index / 2])
                weights.append(index % 2 == 0 ? byte >> 4 : byte & 0x0F)
            }
            cursor += byteCount
        } else {
            // FSE-compressed weights, decoded with two interleaved states.
            let compressedSize = header
            guard compressedSize > 0, compressedSize <= range.upperBound - cursor else { throw Zstd.DecodeError.corrupt("Huffman weights overrun the block") }
            let end = cursor + compressedSize
            var tableCursor = cursor
            let table = try FSETable.read(input, cursor: &tableCursor, end: end, maxAccuracyLog: 7, maxSymbol: 255)
            var bits = try BackwardBits(input, range: tableCursor..<end)
            var state1 = Int(bits.read(table.accuracyLog))
            var state2 = Int(bits.read(table.accuracyLog))
            while true {
                guard weights.count < 255 else { throw Zstd.DecodeError.corrupt("too many Huffman weights") }
                weights.append(Int(table.symbols[state1]))
                state1 = table.nextState(state1, bits.read(Int(table.bitCounts[state1])))
                if bits.position < 0 {
                    weights.append(Int(table.symbols[state2]))
                    break
                }
                weights.append(Int(table.symbols[state2]))
                state2 = table.nextState(state2, bits.read(Int(table.bitCounts[state2])))
                if bits.position < 0 {
                    weights.append(Int(table.symbols[state1]))
                    break
                }
            }
            cursor = end
        }
        consumed = cursor
        return try build(weights: weights)
    }

    static func build(weights explicit: [Int]) throws -> HuffmanTable {
        guard explicit.count <= 255 else { throw Zstd.DecodeError.corrupt("too many Huffman weights") }
        var sum = 0
        for weight in explicit {
            guard weight <= 12 else { throw Zstd.DecodeError.corrupt("Huffman weight too large") }
            if weight > 0 { sum += 1 << (weight - 1) }
        }
        guard sum > 0 else { throw Zstd.DecodeError.corrupt("empty Huffman tree") }
        // The last weight is implied: it completes the sum to the next power of two.
        let maxBits = highestBit(sum) + 1
        guard maxBits <= 12 else { throw Zstd.DecodeError.corrupt("Huffman tree too deep") }
        let leftover = (1 << maxBits) - sum
        guard leftover > 0, leftover & (leftover - 1) == 0 else { throw Zstd.DecodeError.corrupt("Huffman weights don't complete a tree") }
        let weights = explicit + [highestBit(leftover) + 1]

        let bits = weights.map { $0 > 0 ? maxBits + 1 - $0 : 0 }
        var rankCount = [Int](repeating: 0, count: maxBits + 1)
        for count in bits {
            guard count >= 0, count <= maxBits else { throw Zstd.DecodeError.corrupt("bad Huffman code length") }
            rankCount[count] += 1
        }
        let size = 1 << maxBits
        var symbols = [UInt8](repeating: 0, count: size)
        var bitCounts = [UInt8](repeating: 0, count: size)
        // Codes are assigned from the longest length up; each code covers a run of table cells.
        var rankStart = [Int](repeating: 0, count: maxBits + 1)
        var next = 0
        for length in stride(from: maxBits, through: 1, by: -1) {
            rankStart[length] = next
            next += rankCount[length] << (maxBits - length)
        }
        guard next == size else { throw Zstd.DecodeError.corrupt("Huffman table not filled exactly") }
        for (symbol, length) in bits.enumerated() where length > 0 {
            let span = 1 << (maxBits - length)
            let start = rankStart[length]
            for cell in start..<(start + span) {
                symbols[cell] = UInt8(symbol)
                bitCounts[cell] = UInt8(length)
            }
            rankStart[length] += span
        }
        return HuffmanTable(maxBits: maxBits, symbols: symbols, bitCounts: bitCounts)
    }

    /// Decodes one Huffman stream; it must be consumed exactly.
    func decodeStream(_ input: UnsafeBufferPointer<UInt8>, range: Range<Int>, into output: inout [UInt8], limit: Int) throws {
        var bits = try BackwardBits(input, range: range)
        let mask = (1 << maxBits) - 1
        var state = Int(bits.read(maxBits))
        while bits.position > -maxBits {
            guard output.count < limit else { throw Zstd.DecodeError.corrupt("Huffman stream decodes too many literals") }
            output.append(symbols[state])
            let length = Int(bitCounts[state])
            state = ((state << length) + Int(bits.read(length))) & mask
        }
        guard bits.position == -maxBits else { throw Zstd.DecodeError.corrupt("Huffman stream not fully consumed") }
    }
}

// MARK: - XXH64

enum XXH64 {
    private static let prime1: UInt64 = 11_400_714_785_074_694_791
    private static let prime2: UInt64 = 14_029_467_366_897_019_727
    private static let prime3: UInt64 = 1_609_587_929_392_839_161
    private static let prime4: UInt64 = 9_650_029_242_287_828_579
    private static let prime5: UInt64 = 2_870_177_450_012_600_261

    @inline(__always) private static func rotl(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    @inline(__always) private static func round(_ accumulator: UInt64, _ lane: UInt64) -> UInt64 {
        rotl(accumulator &+ lane &* prime2, 31) &* prime1
    }

    @inline(__always) private static func merge(_ hash: UInt64, _ accumulator: UInt64) -> UInt64 {
        (hash ^ round(0, accumulator)) &* prime1 &+ prime4
    }

    static func hash(_ data: [UInt8], seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBufferPointer { buffer in
            let count = buffer.count
            @inline(__always) func u64(_ at: Int) -> UInt64 {
                var value: UInt64 = 0
                for index in 0..<8 { value |= UInt64(buffer[at + index]) << (8 * UInt64(index)) }
                return value
            }
            @inline(__always) func u32(_ at: Int) -> UInt64 {
                var value: UInt64 = 0
                for index in 0..<4 { value |= UInt64(buffer[at + index]) << (8 * UInt64(index)) }
                return value
            }
            var offset = 0
            var hash: UInt64
            if count >= 32 {
                var v1 = seed &+ prime1 &+ prime2
                var v2 = seed &+ prime2
                var v3 = seed
                var v4 = seed &- prime1
                while offset + 32 <= count {
                    v1 = round(v1, u64(offset))
                    v2 = round(v2, u64(offset + 8))
                    v3 = round(v3, u64(offset + 16))
                    v4 = round(v4, u64(offset + 24))
                    offset += 32
                }
                hash = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
                hash = merge(hash, v1)
                hash = merge(hash, v2)
                hash = merge(hash, v3)
                hash = merge(hash, v4)
            } else {
                hash = seed &+ prime5
            }
            hash = hash &+ UInt64(count)
            while offset + 8 <= count {
                hash ^= round(0, u64(offset))
                hash = rotl(hash, 27) &* prime1 &+ prime4
                offset += 8
            }
            if offset + 4 <= count {
                hash ^= u32(offset) &* prime1
                hash = rotl(hash, 23) &* prime2 &+ prime3
                offset += 4
            }
            while offset < count {
                hash ^= UInt64(buffer[offset]) &* prime5
                hash = rotl(hash, 11) &* prime1
                offset += 1
            }
            hash ^= hash >> 33
            hash = hash &* prime2
            hash ^= hash >> 29
            hash = hash &* prime3
            hash ^= hash >> 32
            return hash
        }
    }
}
