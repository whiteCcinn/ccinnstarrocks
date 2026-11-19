import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private typealias F = BackupFixtures

private func payload(_ profiles: [ConnectionProfile], knowledge: BackupKnowledge? = nil, settings: [String: BackupSettingValue]? = nil,
                     history: [BackupHistory]? = nil) -> BackupPayload {
    BackupPayload(profiles: profiles, knowledge: knowledge, settings: settings, history: history)
}

private func onlyItem(_ plan: BackupImportPlan) throws -> BackupProfileItem {
    try #require(plan.profiles.count == 1 ? plan.profiles.first : nil)
}

@Suite("Backup import plan: profiles")
struct BackupProfilePlanTests {
    @Test func anIdenticalProfileIsUnchanged() throws {
        var local = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(10))
        local.lastConnectedAt = F.date(50)
        var imported = local
        imported.updatedAt = F.date(20)
        imported.lastConnectedAt = F.date(30)
        let plan = F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local]))
        let item = try onlyItem(plan)
        #expect(item.status == .unchanged && item.match == .id)
        #expect(item.upsert == nil && item.targetID == local.id)
        #expect(plan.isUnchanged, "when it was saved or last used does not make a difference")
    }

    @Test func aNewProfileIsAdded() throws {
        let imported = F.profile(name: "staging", host: "fe.staging")
        let plan = F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [F.profile(name: "prod", host: "fe.prod")]))
        let item = try onlyItem(plan)
        #expect(item.status == .new && item.match == nil)
        #expect(item.upsert == imported)
        #expect(plan.profileUpserts == [imported])
    }

    @Test func aConflictDefaultsToTheNewerSide() throws {
        let id = UUID()
        let local = F.profile(id: id, name: "prod", host: "fe.prod", updatedAt: F.date(10))
        var newer = local
        newer.name = "prod (renamed)"
        newer.updatedAt = F.date(20)
        let useImported = try onlyItem(F.plan(F.bundle(payload([newer])), local: F.localState(profiles: [local])))
        #expect(useImported.status == .conflict)
        #expect(useImported.resolution == .useImported)
        #expect(useImported.upsert?.name == "prod (renamed)" && useImported.upsert?.id == id)

        var older = newer
        older.updatedAt = F.date(5)
        #expect(try onlyItem(F.plan(F.bundle(payload([older])), local: F.localState(profiles: [local]))).resolution == .keepMine)

        var undated = newer
        undated.updatedAt = nil
        let keepLocal = try onlyItem(F.plan(F.bundle(payload([undated])), local: F.localState(profiles: [local])))
        #expect(keepLocal.resolution == .keepMine && keepLocal.upsert == nil, "without updatedAt on either side the local one stays")
        var undatedLocal = local
        undatedLocal.updatedAt = nil
        #expect(try onlyItem(F.plan(F.bundle(payload([newer])), local: F.localState(profiles: [undatedLocal]))).resolution == .keepMine)
    }

    @Test func anEndpointMatchLandsOnTheLocalID() throws {
        let local = F.profile(name: "prod", host: "fe.prod.example", username: "analyst", updatedAt: F.date(10))
        var imported = F.profile(name: "prod", host: "FE.Prod.Example", username: "analyst", updatedAt: F.date(20))
        imported.createdAt = F.date(-1000)
        let same = try onlyItem(F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local])))
        #expect(same.match == .endpoint)
        #expect(same.targetID == local.id)

        imported.color = .red
        var plan = F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local]))
        let conflict = try onlyItem(plan)
        #expect(conflict.status == .conflict && conflict.resolution == .useImported)
        #expect(conflict.upsert?.id == local.id && conflict.upsert?.color == .red)
        #expect(conflict.upsert?.createdAt == local.createdAt)
        #expect(plan.profileIDMapping == [imported.id: local.id])
        plan.resolve(imported.id, as: .keepMine)
        #expect(plan.profileUpserts.isEmpty && plan.profileIDMapping == [imported.id: local.id])
    }

    @Test func keepBothAddsACopyWithANewIDAndSuffix() throws {
        let local = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(10))
        var imported = local
        imported.port = 9031
        imported.updatedAt = F.date(20)
        var plan = F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local]))
        plan.resolve(imported.id, as: .keepBoth)
        let item = try onlyItem(plan)
        let copy = try #require(item.upsert)
        #expect(copy.id != local.id && copy.id == item.keepBothID)
        #expect(copy.name == "prod (imported)" && copy.port == 9031)
        #expect(plan.profileIDMapping == [imported.id: copy.id])
    }

    @Test func thePrivilegedOptInNeedsAnAuthenticatedBackup() throws {
        var imported = F.profile(name: "prod", host: "fe.prod")
        imported.mcpAccess = .readOnly
        imported.mcpAllowPrivilegedAccount = true
        let untrusted = try onlyItem(F.plan(F.bundle(payload([imported])), local: F.localState()))
        #expect(untrusted.upsert?.mcpAllowPrivilegedAccount == false)
        #expect(untrusted.flags.contains(.privilegedOptInReset))
        #expect(untrusted.flags.contains(.aiAccessChanged))

        let trusted = try onlyItem(F.plan(F.bundle(payload([imported]), authenticated: true), local: F.localState()))
        #expect(trusted.upsert?.mcpAllowPrivilegedAccount == true)
        #expect(!trusted.flags.contains(.privilegedOptInReset))

        // An unauthenticated backup cannot grant the opt-in, nor take away the one given here for the same account.
        var local = imported
        local.updatedAt = F.date(1)
        let reimport = try onlyItem(F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local])))
        #expect(reimport.status == .unchanged)
    }

    @Test func anUnauthenticatedEndpointChangeKeepsTheLocalProfileByDefault() throws {
        let local = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(10))
        var redirected = local
        redirected.host = "evil.example"
        redirected.updatedAt = F.date(999_999)
        let untrusted = try onlyItem(F.plan(F.bundle(payload([redirected])), local: F.localState(profiles: [local])))
        #expect(untrusted.flags.contains(.endpointChanged))
        #expect(untrusted.resolution == .keepMine, "the local password would follow the profile to the new host")
        let trusted = try onlyItem(F.plan(F.bundle(payload([redirected]), authenticated: true), local: F.localState(profiles: [local])))
        #expect(trusted.resolution == .useImported)
    }

    @Test func anUnauthenticatedBackupNeverLoosensASafeguardByDefault() throws {
        var local = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(10))
        local.confirmMutations = true
        var newer = local
        newer.updatedAt = F.date(999_999)
        var moreAccess = newer
        moreAccess.mcpAccess = .readWrite
        var cleartext = newer
        cleartext.allowCleartextPassword = true
        var unconfirmed = newer
        unconfirmed.confirmMutations = false
        let cases: [(ConnectionProfile, BackupProfileItem.Flag)] = [(moreAccess, .aiAccessChanged), (cleartext, .cleartextPasswordEnabled),
                                                                    (unconfirmed, .mutationConfirmationDisabled)]
        for (imported, flag) in cases {
            let untrusted = try onlyItem(F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local])))
            #expect(untrusted.flags.contains(flag))
            #expect(untrusted.resolution == .keepMine)
            let trusted = try onlyItem(F.plan(F.bundle(payload([imported]), authenticated: true), local: F.localState(profiles: [local])))
            #expect(trusted.resolution == .useImported, "the owner's own encrypted backup follows the newer side")
        }
    }

    @Test func secretsFollowTheProfileDecision() throws {
        let local = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(10))
        var changed = local
        changed.name = "prod 2"
        changed.updatedAt = F.date(20)
        let added = F.profile(name: "new", host: "fe.new")
        let imported = [local.id: BackupProfileSecrets(password: "imported-pw", sshSecret: "imported-ssh"),
                        added.id: BackupProfileSecrets(password: "new-pw", sshSecret: nil)]
        let state = F.localState(profiles: [local], secrets: [local.id: BackupProfileSecrets(password: "local-pw", sshSecret: nil)])
        var plan = F.plan(F.bundle(payload([changed, added]), secrets: imported, authenticated: true), local: state)

        let replacedPassword = BackupSecretWrite(key: SecretKey(profileID: local.id, kind: .password), value: "imported-pw")
        let filledSSHSecret = BackupSecretWrite(key: SecretKey(profileID: local.id, kind: .sshSecret), value: "imported-ssh")
        let newPassword = BackupSecretWrite(key: SecretKey(profileID: added.id, kind: .password), value: "new-pw")
        // Use imported (the default here): the local secret is replaced. A new profile receives its secret.
        let useImported: Set<BackupSecretWrite> = [replacedPassword, filledSSHSecret, newPassword]
        #expect(Set(plan.secretWrites) == useImported)
        // Keep mine: the local password stays; a secret missing here is still filled in.
        plan.resolve(local.id, as: .keepMine)
        let keepMine: Set<BackupSecretWrite> = [filledSSHSecret, newPassword]
        #expect(Set(plan.secretWrites) == keepMine)
        // Keep both: the copy receives the imported secrets.
        plan.resolve(local.id, as: .keepBoth)
        let copyID = try #require(plan.profiles.first { $0.id == local.id }).keepBothID
        #expect(plan.secretWrites.filter { $0.key.profileID == copyID }.count == 2)
        #expect(!plan.secretWrites.contains { $0.key.profileID == local.id })
        #expect(!String(describing: plan.secretWrites).contains("imported-pw"))
    }

    @Test func differentSecretsAloneAreAConflict() throws {
        let local = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(10))
        var imported = local
        imported.updatedAt = F.date(20)
        let state = F.localState(profiles: [local], secrets: [local.id: BackupProfileSecrets(password: "old-pw")])
        let bundle = F.bundle(payload([imported]), secrets: [local.id: BackupProfileSecrets(password: "rotated-pw")], authenticated: true)
        let item = try onlyItem(F.plan(bundle, local: state))
        #expect(item.status == .conflict && item.flags.contains(.secretsDiffer))
        #expect(item.resolution == .useImported && item.upsert == nil, "the profile itself does not change")
        let same = F.bundle(payload([imported]), secrets: [local.id: BackupProfileSecrets(password: "old-pw")], authenticated: true)
        #expect(F.plan(same, local: state).isUnchanged)
    }

    @Test func aMissingSSHKeyIsFlagged() throws {
        let profile = F.tunnelledProfile(name: "tunnel", keyPath: "~/.ssh/id_ed25519")
        let missing = try onlyItem(F.plan(F.bundle(payload([profile])), local: F.localState()))
        #expect(missing.flags.contains(.missingSSHKey))
        let present = try onlyItem(F.plan(F.bundle(payload([profile])), local: F.localState(), existing: ["/Users/new/.ssh/id_ed25519"]))
        #expect(!present.flags.contains(.missingSSHKey))
    }

    @Test func aLocalAbsoluteKeyPathEqualsTheImportedTildePath() throws {
        var local = F.tunnelledProfile(name: "tunnel", keyPath: "/Users/new/.ssh/id_ed25519")
        local.updatedAt = F.date(1)
        var imported = local
        imported.ssh?.privateKeyPath = "~/.ssh/id_ed25519"
        #expect(F.plan(F.bundle(payload([imported])), local: F.localState(profiles: [local])).isUnchanged)
    }
}

@Suite("Backup import plan: knowledge, paths, settings, history")
struct BackupContentPlanTests {
    private func knowledgeBundle(_ databases: [DatabaseKnowledge], index: KnowledgeIndex = F.index()) -> BackupBundle {
        F.bundle(payload([], knowledge: BackupKnowledge(index: index, databases: databases)))
    }

    @Test func knowledgeIsMergedItemByItem() throws {
        var local = F.knowledge(notes: [F.note("n1", text: "old text", at: 10), F.note("n2", text: "local only", at: 10)],
                                tables: [F.table("report", fingerprint: "local"), F.table("local_only")], refreshedAt: F.date(100))
        var imported = F.knowledge(notes: [F.note("n1", text: "newer text", at: 20), F.note("n3", text: "imported only", at: 5)],
                                   tables: [F.table("report", fingerprint: "imported"), F.table("imported_only")], refreshedAt: F.date(50))
        let from = Relationship.End(table: "report", columns: ["dsp_id"])
        let to = Relationship.End(table: "dsp", columns: ["id"])
        local.relationships = [Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 55, at: F.date(1))])]
        imported.relationships = [Relationship(from: from, to: to, kind: .manyToOne,
                                               evidence: [Evidence(source: .naming, score: 55, at: F.date(1)),
                                                          Evidence(source: .code, project: "p1", path: "dao.go", line: 7, by: "ai:codex", at: F.date(2))])]

        let (merged, changes) = BackupKnowledgeMerge.merge(local: local, imported: imported)
        #expect(merged.tables.map(\.name).sorted() == ["imported_only", "local_only", "report"])
        #expect(merged.table(named: "report")?.fingerprint == "local", "the newer refresh wins per table")
        #expect(merged.notes.map(\.text) == ["newer text", "local only", "imported only"], "union by id, the newer edit wins")
        #expect(merged.relationships.first?.evidence.count == 2, "evidence is a union without duplicates")
        #expect(changes.notesAdded == 1)
        #expect(changes.notesUpdated == 1)
        #expect(changes.tablesAdded == 1)
        #expect(changes.relationshipsUpdated == 1)

        let plan = F.plan(knowledgeBundle([imported]), local: F.localState(index: F.index(), databases: [local]))
        #expect(plan.knowledge?.databases.first?.status == .merged)
        let again = BackupKnowledgeMerge.merge(local: merged, imported: imported)
        #expect(again.merged == merged && again.changes.isEmpty, "merging twice changes nothing")
    }

    @Test func tombstonesAreHonouredBothWays() {
        var local = F.knowledge(notes: [F.note("n2", text: "deleted on the other Mac", at: 10)])
        local.tombstones = [Tombstone(id: "n1", deletedAt: F.date(30), by: "user")]
        var imported = F.knowledge(notes: [F.note("n1", text: "deleted here", at: 20), F.note("n2", text: "deleted on the other Mac", at: 10)])
        imported.tombstones = [Tombstone(id: "n2", deletedAt: F.date(40), by: "user")]
        imported.notes.removeLast()
        let (merged, changes) = BackupKnowledgeMerge.merge(local: local, imported: imported)
        #expect(merged.notes.isEmpty, "a deleted note never comes back and a deletion travels")
        #expect(Set(merged.tombstones.map(\.id)) == ["n1", "n2"])
        #expect(changes.removed == 1 && changes.notesAdded == 0)
    }

    @Test func aDatabaseThisMacCannotRewriteIsSkipped() throws {
        let plan = F.plan(knowledgeBundle([F.knowledge(notes: [F.note("n1", text: "x", at: 1)])]),
                          local: BackupLocalState(profiles: [], knowledgeIndex: F.index(), knowledgeDatabases: [:],
                                                  unwritableDatabases: [F.databaseKey], settings: [:], history: [:], secrets: [:]))
        #expect(plan.knowledge?.databases.first?.status == .skipped)
        #expect(plan.warnings.contains(.localDatabaseNotWritable(F.databaseKey)))
    }

    @Test func projectPathsExpandUnderTheNewHome() throws {
        let index = F.index(projects: [F.project("p1", path: "~/code/adx")])
        let plan = F.plan(knowledgeBundle([], index: index), local: F.localState(), existing: ["/Users/new/code/adx"])
        let project = try #require(plan.knowledge?.projects.first)
        #expect(project.expandedPath == "/Users/new/code/adx")
        #expect(!project.isMissing && project.localMatch == nil)
    }

    @Test func aMissingPathIsMarkedAndKeepsItsLinks() throws {
        let index = F.index(projects: [F.project("p1", path: "~/code/adx")])
        let plan = F.plan(knowledgeBundle([], index: index), local: F.localState())
        let project = try #require(plan.knowledge?.projects.first)
        #expect(project.isMissing)
        let merged = try #require(plan.knowledge).mergedIndex(into: KnowledgeIndex())
        #expect(merged.projects.map(\.id) == ["p1"] && merged.links.count == 1, "the project and its links are kept")
    }

    @Test func aCommonPrefixRemapAppliesToEveryProject() throws {
        let index = F.index(projects: [F.project("p1", path: "/Volumes/Work/code/adx"), F.project("p2", path: "/Volumes/Work/code/ssp"),
                                       F.project("p3", path: "/opt/other")])
        var plan = F.plan(knowledgeBundle([], index: index), local: F.localState())
        #expect(plan.remapProjects(fromPrefix: "/Volumes/Work/co", toPrefix: "~/x", home: F.newHome, fileExists: { _ in true }) == 0,
                "prefixes match whole path components")
        let existing: Set<String> = ["/Users/new/code/adx", "/Users/new/code/ssp"]
        let remapped = plan.remapProjects(fromPrefix: "/Volumes/Work/code", toPrefix: "~/code", home: F.newHome,
                                          fileExists: { (path: String) -> Bool in existing.contains(path) })
        #expect(remapped == 2)
        let projects = try #require(plan.knowledge?.projects)
        #expect(projects.map(\.path) == ["~/code/adx", "~/code/ssp", "/opt/other"])
        #expect(projects.map(\.isMissing) == [false, false, true])

        let single = plan.remapProject("p3", to: "/Users/new/elsewhere", home: F.newHome, fileExists: { _ in true })
        #expect(single && plan.knowledge?.projects.last?.path == "~/elsewhere")
    }

    @Test func projectsMatchByPathOrGitRemote() throws {
        let local = F.index(projects: [F.project("local-1", path: "~/work/adx", remote: "github.com/org/adx"),
                                       F.project("local-2", path: "~/code/ssp")])
        let imported = F.index(projects: [F.project("p1", path: "~/code/adx-server", remote: "https://GitHub.com/org/adx.git"),
                                          F.project("p2", path: "~/code/ssp")])
        let plan = F.plan(knowledgeBundle([], index: imported), local: F.localState(index: local))
        #expect(plan.knowledge?.projects.map(\.localMatch) == ["local-1", "local-2"])
        let merged = try #require(plan.knowledge).mergedIndex(into: local)
        #expect(merged.projects.count == 2, "matched projects are not added again")
        #expect(Set(merged.links.map(\.project)) == ["local-1", "local-2"], "links move to the local projects")
    }

    @Test func settingsAreWhitelistedAndRangeChecked() throws {
        let settings: [String: BackupSettingValue] = [
            "appearance": .string("Dark"), "autoLimit": .int(5000), "sqlFormatIndent": .int(99), "sqlFormatKeywordCase": .string("upper"),
            "updates.automaticallyCheck": .string("yes"), "settingsTab": .string("mcp"), "updates.lastCheck": .int(5),
        ]
        let local: [String: BackupSettingValue] = ["appearance": .string("Light"), "sqlFormatKeywordCase": .string("upper")]
        let plan = F.plan(F.bundle(payload([], settings: settings)), local: F.localState(settings: local))
        #expect(plan.settings.map(\.key) == ["appearance", "autoLimit", "sqlFormatKeywordCase"])
        #expect(plan.settingChanges.map(\.key) == ["appearance", "autoLimit"])
        let appearance = try #require(plan.settings.first)
        #expect(appearance.current == .string("Light") && appearance.imported == .string("Dark"))
        var expectedWarnings = Set<BackupWarning>()
        expectedWarnings.insert(.invalidSetting("sqlFormatIndent"))
        expectedWarnings.insert(.invalidSetting("updates.automaticallyCheck"))
        expectedWarnings.insert(.unsupportedSetting("settingsTab"))
        expectedWarnings.insert(.unsupportedSetting("updates.lastCheck"))
        #expect(Set(plan.warnings) == expectedWarnings)
    }

    @Test func historyIsRemappedMergedRedactedAndCapped() throws {
        let local = F.profile(name: "prod", host: "fe.prod")
        let imported = F.profile(name: "prod", host: "fe.prod")
        let shared = F.historyEntry("SELECT 1", at: 1)
        let localEntries = [shared] + (0..<600).map { F.historyEntry("SELECT \($0) FROM local", at: Double(-$0)) }
        let importedEntries = [shared, F.historyEntry("CREATE USER x IDENTIFIED BY 'pw-123'", at: 500)]
            + (0..<600).map { F.historyEntry("SELECT \($0) FROM imported", at: Double(-$0) - 0.5) }
        let bundle = F.bundle(payload([imported], history: [BackupHistory(profile: imported.id, entries: importedEntries)]))
        let plan = F.plan(bundle, local: F.localState(profiles: [local], history: [local.id: localEntries]))
        let change = try #require(plan.historyChanges.first)
        #expect(change.profileID == local.id, "history follows the profile to its local id")
        #expect(change.newEntries == 601)

        let merged = BackupHistoryFiles.merge(local: localEntries, imported: try #require(plan.history.first).entries)
        #expect(merged.count == 1_000)
        #expect(merged.first?.sql == "CREATE USER x IDENTIFIED BY '***'", "newest first, redacted again")
        #expect(merged.filter { $0.id == shared.id }.count == 1, "union by entry id")
        let dates = merged.map(\.executedAt)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func reimportingTheSameBundleChangesNothing() throws {
        var profile = F.tunnelledProfile(name: "tunnel", keyPath: "~/.ssh/id")
        profile.updatedAt = F.date(3)
        let knowledge = F.knowledge(notes: [F.note("n1", text: "x", at: 1)], tables: [F.table("report")], refreshedAt: F.date(2))
        let index = F.index(projects: [F.project("p1", path: "~/code/adx")])
        let entries = [F.historyEntry("SELECT 1", at: 1)]
        let settings: [String: BackupSettingValue] = ["autoLimit": .int(500)]
        let bundle = F.bundle(payload([profile], knowledge: BackupKnowledge(index: index, databases: [knowledge]), settings: settings,
                                      history: [BackupHistory(profile: profile.id, entries: entries)]))
        let state = F.localState(profiles: [profile], index: index, databases: [knowledge], settings: settings, history: [profile.id: entries])
        let plan = F.plan(bundle, local: state)
        #expect(plan.isUnchanged)
        #expect(plan.profiles.allSatisfy { $0.status == .unchanged })
        #expect(plan.knowledge?.databases.allSatisfy { $0.status == .unchanged } == true)
        #expect(plan.knowledge?.indexChanges == false)
        #expect(plan.settingChanges.isEmpty)
        #expect(plan.historyChanges.isEmpty)
        #expect(plan.secretWrites.isEmpty)
    }

    @Test func knowledgeWithoutAReachingConnectionIsListed() throws {
        let bundle = knowledgeBundle([F.knowledge(notes: [F.note("n1", text: "x", at: 1)])])
        let unreached = F.plan(bundle, local: F.localState())
        #expect(unreached.knowledge?.databases.first?.hasMatchingConnection == false)
        let reached = F.plan(bundle, local: F.localState(profiles: [F.profile(name: "prod", host: "FE.PROD")]))
        #expect(reached.knowledge?.databases.first?.hasMatchingConnection == true)
    }
}

@Suite("Backup paths")
struct BackupPathTests {
    @Test func homeIsCollapsedAndExpandedOnComponentBoundaries() {
        #expect(BackupPaths.collapsingHome("/Users/old/code/adx", home: "/Users/old") == "~/code/adx")
        #expect(BackupPaths.collapsingHome("/Users/old", home: "/Users/old/") == "~")
        #expect(BackupPaths.collapsingHome("/Users/older/code", home: "/Users/old") == "/Users/older/code")
        #expect(BackupPaths.expandingHome("~/code/adx", home: "/Users/new") == "/Users/new/code/adx")
        #expect(BackupPaths.expandingHome("~", home: "/Users/new") == "/Users/new")
        #expect(BackupPaths.expandingHome("~bob/code", home: "/Users/new") == "~bob/code")
        #expect(BackupPaths.replacingPrefix("/Volumes/Work", with: "~/work", in: "/Volumes/Work/a", home: "/Users/new") == "~/work/a")
        #expect(BackupPaths.replacingPrefix("/Volumes/Work", with: "~/work", in: "/Volumes/Workshop/a", home: "/Users/new") == nil)
        #expect(BackupPaths.isAcceptable("~/code") && BackupPaths.isAcceptable("/opt/x") && BackupPaths.isAcceptable("~"))
        #expect(!BackupPaths.isAcceptable("") && !BackupPaths.isAcceptable("code") && !BackupPaths.isAcceptable("/a/../b"))
    }
}
