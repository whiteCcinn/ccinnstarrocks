import Foundation

/// Confidence (0–100) and status of a relationship, computed from its evidence whenever it is read and never stored
/// (design §2.5). Integer arithmetic only, so the same evidence gives the same number on every Mac.
///
/// - The result is capped at 95 unless a declared constraint (or, for a lineage relationship, lineage) vouches for it;
///   grain-only joins at 35 unless declared; shared keys at 30 while names are their only evidence.
///
/// - Each source has a confidence: user 100, declared 95, lineage 100, definition 85, history
///   `min(90, 55 + 10·log2(distinct statements))`, code 80 per evidence, ai ≤ 50, naming 30–70.
/// - Sources combine by noisy-OR, `1 − Π(1 − cᵢ)`. One source counts once (its best evidence), except `code`, where
///   every pointer into a repository is a witness of its own.
/// - Rejections by anyone but the user lower the result the same way: `support × (1 − Π(1 − rejectᵢ))`.
/// - The user decides: a confirmation scores 100, a rejection 0, whatever else was said.
public enum RelationshipConfidence {
    /// Inferred relationships stop here unless a declared constraint or lineage vouches for them.
    public static let inferredCap = 95
    /// Joins on time columns only (`dt`, `hour`, …): every hourly table matches every other on them.
    public static let grainCap = 35
    /// A key shared by tables without a table that owns it; below the default join-path threshold of 40.
    public static let sharedKeyCap = 30
    /// `naming` evidence never says more than this.
    public static let namingCap = 70
    /// `ai` evidence without anything verifiable.
    public static let aiCap = 50

    /// Column names that mean a point in time (the grain rule), besides `*_time` and `*_date`.
    static let timeColumnNames: Set<String> = ["dt", "ds", "date", "day", "hour", "minute", "ts"]

    public static func score(_ relationship: Relationship) -> Int {
        score(relationship, columnType: { (_: Relationship.End, _: String) -> String? in nil })
    }

    /// `columnType` gives a column's type when known, so date and datetime columns count as time-like whatever
    /// their names.
    public static func score(_ relationship: Relationship, columnType: (Relationship.End, String) -> String?) -> Int {
        if let verdict = userVerdict(relationship.evidence) { return verdict == .assert ? 100 : 0 }
        if relationship.status == .rejected { return 0 }
        let supporting = relationship.evidence.filter { $0.verdict == .assert }
        let opposing = relationship.evidence.filter { $0.verdict == .reject }
        guard !supporting.isEmpty else { return 0 }

        let support: Int = noisyOr(contributions(supporting))
        let doubt: Int = noisyOr(contributions(opposing))
        let combined: Int = support * (partsPerMillion - doubt) / partsPerMillion
        var result: Int = (combined + partsPerMillion / 200) / (partsPerMillion / 100)

        let sources = Set(supporting.map(\.source))
        let declared = sources.contains(.declared)
        let isLineage = relationship.kind == .lineage && sources.contains(.lineage)
        if !declared, !isLineage { result = min(result, inferredCap) }
        if !declared, isGrainJoin(relationship, columnType: columnType) { result = min(result, grainCap) }
        if relationship.kind == .sharedKey, sources == [.naming] { result = min(result, sharedKeyCap) }
        return max(0, min(100, result))
    }

    /// The user's latest verdict sets confirmed or rejected; anything else leaves the relationship inferred (an AI
    /// rejection only lowers the score).
    public static func status(_ relationship: Relationship) -> Relationship.Status {
        switch userVerdict(relationship.evidence) {
        case .assert?: .confirmed
        case .reject?: .rejected
        case nil: .inferred
        }
    }

    /// One evidence's own confidence, before sources are combined and capped.
    public static func confidence(of evidence: Evidence) -> Int {
        let value: Int
        switch evidence.source {
        case .user, .lineage: value = 100
        case .declared: value = 95
        case .definition: value = 85
        case .code: value = 80
        case .history: value = historyConfidence(statements: evidence.statements ?? 1)
        case .ai: value = min(evidence.score ?? aiCap, aiCap)
        case .naming: value = min(evidence.score ?? 30, namingCap)
        }
        return max(0, min(100, value))
    }

    /// Every column on both ends is time-like by name (`dt`, `ds`, `date`, `day`, `hour`, `minute`, `ts`, `*_time`,
    /// `*_date`). Grain columns next to a key pair make a composite key instead, which is no grain join.
    public static func isGrainJoin(_ relationship: Relationship) -> Bool {
        isGrainJoin(relationship, columnType: { (_: Relationship.End, _: String) -> String? in nil })
    }

    /// Same, with date and datetime types counting as time-like too.
    public static func isGrainJoin(_ relationship: Relationship, columnType: (Relationship.End, String) -> String?) -> Bool {
        let ends = [relationship.from, relationship.to]
        guard ends.allSatisfy({ !$0.columns.isEmpty }) else { return false }
        for end in ends {
            for column in end.columns where !isTimeLike(column, type: columnType(end, column)) { return false }
        }
        return true
    }

    // MARK: Arithmetic

    private static let partsPerMillion = 1_000_000

    /// `min(90, 55 + ⌊10·log2 n⌋)` without floating point: ⌊10·log2 n⌋ is the largest k with 2^k ≤ n^10.
    static func historyConfidence(statements: Int) -> Int {
        guard statements > 0 else { return 0 }
        // 55 + ⌊10·log2 12⌋ = 90; beyond that the cap holds, and n^10 stays far from overflowing below it.
        guard statements < 12 else { return 90 }
        var power = 1
        for _ in 0..<10 { power *= statements }
        var exponent = 0
        while (1 << (exponent + 1)) <= power { exponent += 1 }
        return min(90, 55 + exponent)
    }

    /// Confidence per counted witness: each `code` evidence, and the best of every other source.
    private static func contributions(_ evidence: [Evidence]) -> [Int] {
        var bestBySource: [Evidence.Source: Int] = [:]
        var witnesses: [Int] = []
        for item in evidence {
            let value = confidence(of: item)
            if item.source == .code {
                witnesses.append(value)
            } else {
                bestBySource[item.source] = max(bestBySource[item.source] ?? 0, value)
            }
        }
        // Sorted, so rounding never depends on the order evidence was stored in.
        return (witnesses + Array(bestBySource.values)).sorted()
    }

    /// `1 − Π(1 − cᵢ/100)` in parts per million.
    private static func noisyOr(_ confidences: [Int]) -> Int {
        var remaining = partsPerMillion
        for confidence in confidences {
            let doubt: Int = 100 - max(0, min(100, confidence))
            remaining = remaining * doubt / 100
        }
        return partsPerMillion - remaining
    }

    private static func userVerdict(_ evidence: [Evidence]) -> Evidence.Verdict? {
        var latest: (at: Date, verdict: Evidence.Verdict)?
        for item in evidence where item.source == .user {
            let at = item.at ?? .distantPast
            if let current = latest, at < current.at { continue }
            latest = (at, item.verdict)
        }
        return latest?.verdict
    }

    static func isTimeLike(_ column: String, type: String?) -> Bool {
        let name = column.lowercased()
        if timeColumnNames.contains(name) || name.hasSuffix("_time") || name.hasSuffix("_date") { return true }
        guard let type else { return false }
        return ColumnTypeFamily(type) == .temporal
    }
}
