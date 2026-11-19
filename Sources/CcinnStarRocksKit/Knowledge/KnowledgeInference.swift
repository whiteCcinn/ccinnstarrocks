import Foundation
import StarRocksKit

/// Relationships from every machine source for one refresh: declared constraints, joins inside view and materialized
/// view definitions, joins in the editor history, and names. The refresher merges them (one record per pair of ends)
/// and keeps what the user and AI added.
public enum KnowledgeInference {
    public static let machineRelationships: KnowledgeToolSettings.Inference = { (input: KnowledgeInferenceInput) -> [Relationship] in
        let knowledge = input.knowledge
        let live = knowledge.tables.filter { $0.state != .dropped }
        var relationships = declared(input.schema, knowledge: knowledge, now: input.now)
        relationships += NamingHeuristics.relationships(tables: live, now: input.now)
        relationships += HistoryJoinMiner.relationships(entries: input.history, knowledge: knowledge, now: input.now)
        for table in input.schema.tables {
            guard let definition = table.definition, table.object.kind != .table else { continue }
            relationships += HistoryJoinMiner.definitionRelationships(definition: definition, viewName: table.object.name, knowledge: knowledge, now: input.now)
        }
        return relationships
    }

    /// `foreign_key_constraints` table properties as many-to-one relationships with `declared` evidence.
    static func declared(_ schema: ExtractedSchema, knowledge: DatabaseKnowledge, now: Date) -> [Relationship] {
        var result: [Relationship] = []
        for table in schema.tables {
            guard let property = table.object.properties["foreign_key_constraints"], !property.isEmpty else { continue }
            for key in ForeignKeyConstraintParser.foreignKeys(property) {
                let database: String? = key.target.database.flatMap { $0 == schema.database ? nil : $0 }
                let from = Relationship.End(table: table.object.name, columns: key.columns)
                let to = Relationship.End(database: database, table: key.target.table, columns: key.targetColumns)
                result.append(Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .declared, at: now)]))
            }
        }
        return result
    }
}
