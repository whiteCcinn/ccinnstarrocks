import Foundation

/// How to join two tables: the most trustworthy chains of relationships between them, with their conditions, a SQL
/// skeleton and warnings when rows would multiply.
///
/// The graph holds tables (this database's by name, others' as `db.table`) and, for each pair, its strongest usable
/// relationship: not rejected, not lineage, not broken, not stale, and at least `minConfidence`. A hop costs
/// `−ln(confidence) + 0.15`, so a short chain of strong links wins over a long or weak one. The best path comes from
/// Dijkstra, alternatives from Yen's algorithm.
public enum JoinPathFinder {
    public struct Step: Codable, Sendable, Equatable {
        public var join: String
        public var on: String
        public var cardinality: String
        public var confidence: Int
        public var sources: [String]
    }

    public struct Path: Codable, Sendable, Equatable {
        /// The weakest link.
        public var minConfidence: Int
        public var steps: [Step]
        public var sql: String
        public var warnings: [String]
    }

    public struct Excluded: Codable, Sendable, Equatable {
        public var stale = 0
        public var belowMinimum = 0
    }

    public struct Nearest: Codable, Sendable, Equatable {
        public var from: [String]
        public var to: [String]
    }

    public struct Result: Codable, Sendable, Equatable {
        public var paths: [Path]
        public var excluded: Excluded
        /// When no path exists: what each side does connect to.
        public var nearest: Nearest?
    }

    struct Edge {
        let relationship: Relationship
        let confidence: Int
        let weight: Double
    }

    struct Graph {
        var neighbours: [String: [String]] = [:]
        var edges: [String: Edge] = [:]

        static func key(_ left: String, _ right: String) -> String {
            left < right ? left + "\u{1F}" + right : right + "\u{1F}" + left
        }

        func edge(_ left: String, _ right: String) -> Edge? { edges[Self.key(left, right)] }
    }

    public static func find(from: String, to: String, through: [String] = [], in knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int,
                            maxHops: Int = 4, minConfidence: Int = 40, alternatives: Int = 2) -> Result {
        let (graph, excluded) = buildGraph(knowledge, confidence: confidence, minConfidence: minConfidence)
        let hops = min(max(maxHops, 1), 6)
        var nodePaths: [[String]] = []
        if through.isEmpty {
            nodePaths = kShortest(graph, from: from, to: to, count: min(max(alternatives, 1), 3)).filter { $0.count - 1 <= hops }
        } else {
            var combined: [String] = [from]
            let waypoints = [from] + through + [to]
            var complete = true
            for index in 0..<(waypoints.count - 1) {
                guard let segment = shortest(graph, from: waypoints[index], to: waypoints[index + 1], bannedEdges: [], bannedNodes: []) else {
                    complete = false
                    break
                }
                combined += segment.dropFirst()
            }
            if complete, combined.count - 1 <= hops * max(1, waypoints.count - 1) { nodePaths = [combined] }
        }
        let paths = nodePaths.map { describe($0, graph: graph) }
        var nearest: Nearest?
        if paths.isEmpty {
            nearest = Nearest(from: neighbourhood(graph, of: from), to: neighbourhood(graph, of: to))
        }
        return Result(paths: paths, excluded: excluded, nearest: nearest)
    }

    // MARK: Graph

    static func buildGraph(_ knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int, minConfidence: Int) -> (Graph, Excluded) {
        var graph = Graph()
        var excluded = Excluded()
        let live = Set(knowledge.tables.filter { $0.state != .dropped }.map(\.name))
        for relationship in knowledge.relationships {
            guard relationship.kind != .lineage, !KnowledgeRules.isRejected(relationship) else { continue }
            let left = KnowledgeRules.node(relationship.from)
            let right = KnowledgeRules.node(relationship.to)
            guard left != right else { continue }
            let leftLive = relationship.from.database != nil || live.contains(relationship.from.table)
            let rightLive = relationship.to.database != nil || live.contains(relationship.to.table)
            guard leftLive, rightLive, !KnowledgeFreshness.isBroken(relationship, in: knowledge) else { continue }
            if KnowledgeFreshness.isStale(relationship, in: knowledge) {
                excluded.stale += 1
                continue
            }
            let score = min(max(confidence(relationship), 0), 100)
            guard score >= minConfidence, score > 0 else {
                excluded.belowMinimum += 1
                continue
            }
            let probability: Double = Double(score) / 100
            let weight: Double = -log(probability) + 0.15
            let key = Graph.key(left, right)
            if let existing = graph.edges[key], existing.confidence >= score { continue }
            if graph.edges[key] == nil {
                graph.neighbours[left, default: []].append(right)
                graph.neighbours[right, default: []].append(left)
            }
            graph.edges[key] = Edge(relationship: relationship, confidence: score, weight: weight)
        }
        for node in graph.neighbours.keys { graph.neighbours[node]?.sort() }
        return (graph, excluded)
    }

    /// Dijkstra; ties broken by node name so results are deterministic.
    static func shortest(_ graph: Graph, from: String, to: String, bannedEdges: Set<String>, bannedNodes: Set<String>) -> [String]? {
        guard from != to else { return nil }
        var distance: [String: Double] = [from: 0]
        var previous: [String: String] = [:]
        var settled: Set<String> = []
        while true {
            var current: String?
            var best = Double.infinity
            for (node, value) in distance where !settled.contains(node) {
                if value < best || (value == best && node < (current ?? "\u{10FFFF}")) {
                    best = value
                    current = node
                }
            }
            guard let node = current else { return nil }
            if node == to { break }
            settled.insert(node)
            for neighbour in graph.neighbours[node] ?? [] where !settled.contains(neighbour) && !bannedNodes.contains(neighbour) {
                let key = Graph.key(node, neighbour)
                guard !bannedEdges.contains(key), let edge = graph.edges[key] else { continue }
                let candidate: Double = best + edge.weight
                if candidate < (distance[neighbour] ?? .infinity) {
                    distance[neighbour] = candidate
                    previous[neighbour] = node
                }
            }
        }
        var path: [String] = [to]
        var node = to
        while let before = previous[node] {
            path.insert(before, at: 0)
            node = before
        }
        return path.first == from ? path : nil
    }

    static func cost(_ path: [String], _ graph: Graph) -> Double {
        var total: Double = 0
        for index in 0..<max(0, path.count - 1) { total += graph.edge(path[index], path[index + 1])?.weight ?? .infinity }
        return total
    }

    /// Yen's k shortest loopless paths.
    static func kShortest(_ graph: Graph, from: String, to: String, count: Int) -> [[String]] {
        guard let first = shortest(graph, from: from, to: to, bannedEdges: [], bannedNodes: []) else { return [] }
        var accepted: [[String]] = [first]
        var candidates: [[String]] = []
        while accepted.count < count, let last = accepted.last {
            for index in 0..<(last.count - 1) {
                let spur = last[index]
                let root = Array(last[0...index])
                var bannedEdges: Set<String> = []
                for path in accepted where path.count > index + 1 && Array(path[0...index]) == root {
                    bannedEdges.insert(Graph.key(path[index], path[index + 1]))
                }
                let bannedNodes = Set(root.dropLast())
                guard let tail = shortest(graph, from: spur, to: to, bannedEdges: bannedEdges, bannedNodes: bannedNodes) else { continue }
                let candidate = root + tail.dropFirst()
                if !accepted.contains(candidate), !candidates.contains(candidate) { candidates.append(candidate) }
            }
            guard !candidates.isEmpty else { break }
            candidates.sort { (left: [String], right: [String]) -> Bool in
                let leftCost = cost(left, graph)
                let rightCost = cost(right, graph)
                return leftCost != rightCost ? leftCost < rightCost : left.joined(separator: ",") < right.joined(separator: ",")
            }
            accepted.append(candidates.removeFirst())
        }
        return accepted
    }

    static func neighbourhood(_ graph: Graph, of node: String) -> [String] {
        let direct = (graph.neighbours[node] ?? []).sorted { (left: String, right: String) -> Bool in
            let leftScore = graph.edge(node, left)?.confidence ?? 0
            let rightScore = graph.edge(node, right)?.confidence ?? 0
            return leftScore != rightScore ? leftScore > rightScore : left < right
        }
        return Array(direct.prefix(5))
    }

    // MARK: Description

    static func describe(_ nodes: [String], graph: Graph) -> Path {
        var steps: [Step] = []
        var sql = "FROM " + quoted(nodes[0])
        for index in 0..<(nodes.count - 1) {
            let origin = nodes[index]
            let target = nodes[index + 1]
            guard let edge = graph.edge(origin, target) else { continue }
            let on = KnowledgeRules.condition(edge.relationship, leftFirst: origin)
            steps.append(Step(join: target, on: on, cardinality: KnowledgeRules.cardinality(edge.relationship, from: origin), confidence: edge.confidence,
                              sources: KnowledgeRules.sources(edge.relationship)))
            sql += "\nJOIN " + quoted(target) + " ON " + quotedCondition(edge.relationship, leftFirst: origin)
        }
        return Path(minConfidence: steps.map(\.confidence).min() ?? 0, steps: steps, sql: sql, warnings: warnings(steps, nodes: nodes))
    }

    static func warnings(_ steps: [Step], nodes: [String]) -> [String] {
        var warnings: [String] = []
        var dimension: String?
        for (index, step) in steps.enumerated() {
            if step.cardinality == "n:1" { dimension = nodes[index + 1] }
            if step.cardinality == "1:n", let through = dimension {
                warnings.append("\(nodes[0]) and \(step.join) are both on the many side of \(through): joining them multiplies rows; aggregate each side to the shared key first.")
                dimension = nil
            }
            if step.cardinality == "n:n" || step.cardinality == "shared" {
                warnings.append("\(nodes[index]) to \(step.join) is many-to-many: rows multiply; aggregate first or join on a unique key.")
            }
        }
        return warnings
    }

    static func quoted(_ node: String) -> String {
        node.split(separator: ".", maxSplits: 1).map { CompletionEngine.quoteIfNeeded(String($0)) }.joined(separator: ".")
    }

    static func quotedCondition(_ relationship: Relationship, leftFirst left: String) -> String {
        let fromNode = KnowledgeRules.node(relationship.from)
        let toNode = KnowledgeRules.node(relationship.to)
        let pairs: [String] = zip(relationship.from.columns, relationship.to.columns).map { (pair: (String, String)) -> String in
            let fromSide = quoted(fromNode) + "." + CompletionEngine.quoteIfNeeded(pair.0)
            let toSide = quoted(toNode) + "." + CompletionEngine.quoteIfNeeded(pair.1)
            return fromNode == left ? fromSide + " = " + toSide : toSide + " = " + fromSide
        }
        return pairs.joined(separator: " AND ")
    }
}
