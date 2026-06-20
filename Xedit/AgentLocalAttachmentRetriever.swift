//
//  AgentLocalAttachmentRetriever.swift
//  WillDeep
//
//  Provider-agnostic local retrieval for attached files. Providers such as
//  DeepSeek only see chat text, so large attachments are compacted into the
//  chunks most relevant to the user's current request before dispatch.
//

import Foundation

enum AgentLocalAttachmentRetriever {
    private static let fullTextThreshold = 8_000
    private static let chunkTargetLength = 1_200
    private static let chunkOverlapLength = 180
    private static let maxReturnedChunks = 4
    private static let maxRenderedCharacters = 14_000

    static func renderAttachment(relativePath: String, body: String, query: String) -> String {
        let normalizedBody = stripOuterFence(from: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedBody.count > fullTextThreshold else {
            return fenced(normalizedBody.isEmpty ? "(file contains no readable text)" : normalizedBody)
        }

        let chunks = makeChunks(from: normalizedBody)
        let terms = queryTerms(from: query)
        let ranked = rank(chunks: chunks, terms: terms, query: query)
        let selected = ranked.prefix(maxReturnedChunks).sorted { $0.chunk.index < $1.chunk.index }

        guard !selected.isEmpty else {
            return fenced(limit(normalizedBody, to: maxRenderedCharacters))
        }

        let displayQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "[local attachment retrieval]",
            "File: \(relativePath)",
            "Query: \(displayQuery.isEmpty ? "(empty user request)" : displayQuery)",
            "Showing \(selected.count) of \(chunks.count) chunks selected from the attachment."
        ]

        for item in selected {
            lines.append("")
            lines.append("--- chunk \(item.chunk.index + 1), score \(item.score) ---")
            lines.append(item.chunk.text)
        }

        return fenced(limit(lines.joined(separator: "\n"), to: maxRenderedCharacters))
    }

    private static func rank(chunks: [Chunk], terms: Set<String>, query: String) -> [RankedChunk] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chunks
            .map { chunk in
                let text = chunk.text.lowercased()
                var score = 0
                for term in terms where !term.isEmpty {
                    if text.contains(term) {
                        score += term.count >= 4 ? 4 : 2
                    }
                }
                if !trimmedQuery.isEmpty, text.contains(trimmedQuery) {
                    score += 12
                }
                if chunk.index == 0 {
                    score += 1
                }
                return RankedChunk(chunk: chunk, score: score)
            }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score == $1.score {
                    return $0.chunk.index < $1.chunk.index
                }
                return $0.score > $1.score
            }
    }

    private static func makeChunks(from text: String) -> [Chunk] {
        let paragraphs = text.components(separatedBy: .newlines)
        var chunks: [Chunk] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                current = ""
                return
            }
            chunks.append(Chunk(index: chunks.count, text: trimmed))
            current = overlapSuffix(from: trimmed)
        }

        for paragraph in paragraphs {
            let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if current.count + line.count + 1 > chunkTargetLength {
                flush()
            }
            current = current.isEmpty ? line : current + "\n" + line
        }
        flush()

        if chunks.isEmpty {
            return strideChunks(from: text)
        }
        return chunks
    }

    private static func strideChunks(from text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkTargetLength, limitedBy: text.endIndex) ?? text.endIndex
            let slice = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty {
                chunks.append(Chunk(index: chunks.count, text: slice))
            }
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -min(chunkOverlapLength, text.distance(from: start, to: end)))
        }
        return chunks
    }

    private static func overlapSuffix(from text: String) -> String {
        guard text.count > chunkOverlapLength else { return text }
        let start = text.index(text.endIndex, offsetBy: -chunkOverlapLength)
        return String(text[start...])
    }

    private static func queryTerms(from query: String) -> Set<String> {
        var terms = Set<String>()
        let lower = query.lowercased()
        let lexical = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        terms.formUnion(lexical)

        let cjkScalars = lower.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
        let cjk = String(String.UnicodeScalarView(cjkScalars))
        let chars = Array(cjk)
        if chars.count >= 2 {
            for index in 0..<(chars.count - 1) {
                terms.insert(String(chars[index...index + 1]))
            }
        } else if chars.count == 1 {
            terms.insert(String(chars[0]))
        }
        return terms
    }

    private static func stripOuterFence(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return body }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return body }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    private static func fenced(_ body: String) -> String {
        "```\n\(body)\n```"
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<end])\n\n[truncated at \(maxCharacters) chars]"
    }
}

private struct Chunk {
    let index: Int
    let text: String
}

private struct RankedChunk {
    let chunk: Chunk
    let score: Int
}
