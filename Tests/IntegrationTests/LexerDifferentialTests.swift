import CcinnStarRocksKit
import Foundation
import Testing
@testable import StarRocksKit

/// The shared lexer is a security boundary: the read-only guard, statement splitting, AutoLimit and the confirmations
/// all see what it sees. This sends every probed code point X to the server over raw COM_QUERY (not through the mysql
/// CLI, which rewrites `#` and more) and checks that the lexer reads X as the server does: part of a name, a separator
/// (the server drops it), something that hides the rest (a comment or string start), or another token. Where the two
/// disagree, the read-only guard must refuse, and wherever the server reaches INTO OUTFILE, the guard must refuse.
///
/// Quick mode (every run): ASCII, Latin-1, notable BMP points and samples from every supplementary plane.
/// `CCINNSR_IT_LEXER_SWEEP=full`: every BMP code point (long-running; release checks only).
@Suite("Lexer versus server", .serialized)
struct LexerDifferentialTests {
    enum Reading: Equatable, CustomStringConvertible {
        case namePart, separator, hidesRest, other
        var description: String {
            switch self {
            case .namePart: "name part"
            case .separator: "separator"
            case .hidesRest: "hides the rest"
            case .other: "other token"
            }
        }
    }

    static var codePoints: [UInt32] {
        if ProcessInfo.processInfo.environment["CCINNSR_IT_LEXER_SWEEP"] == "full" {
            return Array(0x00...0xD7FF) + Array(0xE000...0xFFFF) + supplementarySamples
        }
        let notable: [UInt32] = [0x00AD, 0x02BC, 0x0300, 0x0378, 0x061C, 0x1680, 0x180E, 0x2000, 0x2007, 0x200B, 0x200C, 0x200D,
                                 0x200E, 0x200F, 0x2028, 0x2029, 0x202A, 0x202E, 0x202F, 0x205F, 0x2060, 0x2066, 0x206F, 0x3000,
                                 0x30FB, 0xFE0F, 0xFEFF, 0xFF03, 0xFF1B, 0xFFF9, 0xFFFC, 0xFFFD, 0xFFFE, 0xFFFF]
        return Array(0x00...0xFF) + notable + supplementarySamples
    }

    static let supplementarySamples: [UInt32] = (1...16).flatMap { plane -> [UInt32] in
        let base = UInt32(plane) << 16
        return [base, base + 0x20, base + 0xFFFD, base + 0xFFFF]
    } + [0x1F600, 0x1D400, 0xE0001, 0xE0020, 0xE007F, 0x10FFFF]

    static func text(_ codePoint: UInt32) -> String {
        Unicode.Scalar(codePoint).map { String(Character($0)) } ?? ""
    }

    /// How the lexer reads X in `a<X>b`.
    static func lexerReading(_ x: String) -> Reading {
        let source = "a\(x)b"
        let lexer = SQLLexer(source)
        let tokens = lexer.tokens()
        let texts = tokens.map { lexer.text(of: $0) }
        if tokens.count == 1, texts[0] == source, tokens[0].kind == .identifier || tokens[0].kind == .keyword { return .namePart }
        // `;` splits too (a statement separator), and the server then fails on `b`, like after a dropped character.
        if texts == ["a", "b"] || (texts == ["a", ";", "b"] && tokens[1].kind == .punctuation) { return .separator }
        if texts.first == "a", tokens.count == 2, [.comment, .string, .quotedIdentifier].contains(tokens[1].kind),
           tokens[1].range.upperBound == lexer.units.count, !texts[1].hasSuffix("b") || texts[1].count > 1 { return .hidesRest }
        return .other
    }

    /// How the server reads X: `SELECT 1 AS a<X>b`.
    static func serverReading(_ session: SQLSession, _ x: String) async -> (Reading, String) {
        do {
            let results = try await session.run("SELECT 1 AS a\(x)b")
            let labels = results.first?.columnNames ?? []
            if labels == ["a\(x)b"] { return (.namePart, "label \(labels)") }
            if labels == ["a"] { return (.hidesRest, "label \(labels)") }
            return (.other, "labels \(labels)")
        } catch {
            let message = (error as? StarRocksError)?.message ?? "\(error)"
            if message.contains("Unexpected input 'b'") { return (.separator, message) }
            return (.other, message)
        }
    }

    /// Whether the server parsed `SELECT 1<X>INTO<X>OUTFILE<X>'nosuchscheme://x/'` as an export.
    /// The analyzer only resolves the target's file system once it has parsed an INTO OUTFILE export.
    static func reachesExport(_ message: String) -> Bool {
        message.contains("No FileSystem for scheme \"nosuchscheme\"")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func theLexerReadsEveryCharacterAsTheServerDoes(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let points = Self.codePoints
        let lanes = 8
        let sessions = (0..<lanes).map { _ in client.openSession() }
        struct Finding: Sendable { let point: UInt32; let server: Reading; let lexer: Reading; let detail: String; let exported: Bool; let exportMessage: String }
        let findings = await withTaskGroup(of: [Finding].self) { group -> [Finding] in
            for lane in 0..<lanes {
                let session = sessions[lane]
                let mine = stride(from: lane, to: points.count, by: lanes).map { points[$0] }
                group.addTask {
                    var found: [Finding] = []
                    for point in mine {
                        let x = Self.text(point)
                        guard !x.isEmpty else { continue }
                        let (server, detail) = await Self.serverReading(session, x)
                        let exportSQL = "SELECT 1\(x)INTO\(x)OUTFILE\(x)'nosuchscheme://x/'"
                        var exported = false
                        var exportMessage = ""
                        do {
                            _ = try await session.run(exportSQL)
                            exportMessage = "succeeded"
                        } catch {
                            exportMessage = (error as? StarRocksError)?.message ?? "\(error)"
                            exported = Self.reachesExport(exportMessage)
                        }
                        found.append(Finding(point: point, server: server, lexer: Self.lexerReading(x), detail: detail, exported: exported,
                                             exportMessage: exportMessage))
                    }
                    return found
                }
            }
            var all: [Finding] = []
            for await part in group { all += part }
            return all.sorted { $0.point < $1.point }
        }
        for session in sessions { await session.close() }

        var mismatches: [String] = []
        var unguarded: [String] = []
        for finding in findings {
            let x = Self.text(finding.point)
            let label = String(format: "U+%04X", finding.point)
            if finding.server != finding.lexer {
                mismatches.append("\(label): server \(finding.server), lexer \(finding.lexer) (\(finding.detail.prefix(80)))")
                if ReadOnlySQLGuard.check("SELECT 1 AS a\(x)b") == nil { unguarded.append("\(label) not refused by the guard") }
                if SQLFormatter.format("SELECT 1 AS a\(x)b") != nil { unguarded.append("\(label) not refused by the formatter") }
            }
            let exportSQL = "SELECT 1\(x)INTO\(x)OUTFILE\(x)'nosuchscheme://x/'"
            if finding.exported, ReadOnlySQLGuard.check(exportSQL) == nil {
                unguarded.append("\(label): the server reaches INTO OUTFILE but the guard allows it (\(finding.exportMessage.prefix(80)))")
            }
        }
        let separators = findings.filter { $0.server == .separator }.map { String(format: "U+%04X", $0.point) }
        print("LEXER-DIFF[\(target.label)] probed \(findings.count); server separators: \(separators.joined(separator: " "))")
        for line in mismatches { print("LEXER-DIFF[\(target.label)] mismatch \(line)") }
        let exportSample: String = findings.first(where: { $0.point == 0x20 }).map(\.exportMessage) ?? ""
        print("LEXER-DIFF[\(target.label)] export message for a space: \(exportSample.prefix(160))")
        #expect(findings.first { $0.point == 0x20 }?.exported == true, "the export probe is recognised: \(exportSample)")
        #expect(unguarded.isEmpty, "\(unguarded)")
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches")
    }
}
