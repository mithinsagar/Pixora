import Foundation

/// Turns what someone typed into the numbers the search model reads: lower case, spaces become "▁", then byte-pair merges
/// in rank order. Characters the vocabulary doesn't have fall back to their UTF-8 bytes. Same output as the model's own tokenizer.
public struct SightTokenizer: Sendable {
    public static let length = 64
    private static let endToken: Int32 = 1, firstByteToken: Int32 = 217, magic: UInt32 = 0x50585331

    private let singles: [UInt32: Int32]
    /// (left << 32 | right) → the merge's rank and the token it makes.
    private let merges: [UInt64: (rank: Int32, token: Int32)]

    public init(singles: [UInt32: Int32], merges: [(left: Int32, right: Int32, token: Int32)]) {
        self.singles = singles
        var table = [UInt64: (rank: Int32, token: Int32)](minimumCapacity: merges.count)
        for (rank, m) in merges.enumerated() {
            let key = Self.key(m.left, m.right)
            if table[key] == nil { table[key] = (Int32(rank), m.token) }
        }
        self.merges = table
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let words: [UInt32] = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        guard words.count >= 3, words[0] == Self.magic, words.count == 3 + Int(words[1]) * 2 + Int(words[2]) * 3 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var singles = [UInt32: Int32](minimumCapacity: Int(words[1]))
        var at = 3
        for _ in 0..<Int(words[1]) { singles[words[at]] = Int32(words[at + 1]); at += 2 }
        var merges: [(left: Int32, right: Int32, token: Int32)] = []
        merges.reserveCapacity(Int(words[2]))
        for _ in 0..<Int(words[2]) { merges.append((Int32(words[at]), Int32(words[at + 1]), Int32(words[at + 2]))); at += 3 }
        self.init(singles: singles, merges: merges)
    }

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 { UInt64(UInt32(left)) << 32 | UInt64(UInt32(right)) }

    /// Always `length` long: the tokens, the end marker, then padding.
    public func encode(_ text: String) -> [Int32] {
        var tokens = merged(symbols(text))
        tokens = Array(tokens.prefix(Self.length - 1)) + [Self.endToken]
        return tokens + Array(repeating: 0, count: Self.length - tokens.count)
    }

    private func symbols(_ text: String) -> [Int32] {
        let cleaned = text.lowercased().replacingOccurrences(of: " ", with: "▁")
        var out: [Int32] = []
        for scalar in cleaned.unicodeScalars.prefix(512) {
            if let token = singles[scalar.value] { out.append(token); continue }
            out += String(scalar).utf8.map { Self.firstByteToken + Int32($0) }
        }
        return out
    }

    private func merged(_ start: [Int32]) -> [Int32] {
        var tokens = start
        while tokens.count > 1 {
            var best: (index: Int, rank: Int32, token: Int32)?
            for i in 0..<(tokens.count - 1) {
                if let m = merges[Self.key(tokens[i], tokens[i + 1])], m.rank < (best?.rank ?? .max) { best = (i, m.rank, m.token) }
            }
            guard let best else { break }
            tokens[best.index] = best.token
            tokens.remove(at: best.index + 1)
        }
        return tokens
    }
}
