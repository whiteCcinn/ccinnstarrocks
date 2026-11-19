import CcinnStarRocksKit
import Foundation
import Observation

/// Shared, observable list of saved connection profiles (persisted via `ProfileRepository`).
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile] = []
    var lastError: String?
    let repository: ProfileRepository

    init(repository: ProfileRepository = ProfileRepository()) {
        self.repository = repository
        do {
            profiles = try repository.load()
        } catch {
            lastError = "Could not read saved connections: \(error.localizedDescription)"
        }
    }

    var favorites: [ConnectionProfile] { profiles.filter(\.isFavorite).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var recents: [ConnectionProfile] { Array(ConnectionProfile.recents(profiles.filter { !$0.isFavorite }).prefix(10)) }
    var others: [ConnectionProfile] {
        let recentIDs = Set(recents.map(\.id))
        return profiles.filter { !$0.isFavorite && !recentIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func profile(id: UUID?) -> ConnectionProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Inserts or updates a profile; secrets go to the Keychain, never to the profile file.
    @discardableResult
    func save(_ profile: ConnectionProfile, password: String?, sshSecret: String?) throws -> ConnectionProfile {
        var profile = profile
        profile.updatedAt = Date()
        try repository.storeSecrets(for: profile, password: password, sshSecret: sshSecret)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
        return profile
    }

    func delete(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? repository.delete(profile)
        try? persist()
    }

    func duplicate(_ profile: ConnectionProfile) -> ConnectionProfile? {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.displayName + " copy"
        copy.lastConnectedAt = nil
        copy.createdAt = Date()
        copy.isFavorite = false
        return try? save(copy, password: password(for: profile), sshSecret: sshSecret(for: profile))
    }

    func setMCPAccess(_ access: MCPAccess, for profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mcpAccess = access
        profiles[index].updatedAt = Date()
        try? persist()
    }

    func setMCPAllowPrivilegedAccount(_ allowed: Bool, for profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mcpAllowPrivilegedAccount = allowed
        profiles[index].updatedAt = Date()
        try? persist()
    }

    func setMCPKnowledgeWrites(_ allowed: Bool, for profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mcpKnowledgeWrites = allowed
        profiles[index].updatedAt = Date()
        try? persist()
    }

    func toggleFavorite(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].isFavorite.toggle()
        profiles[index].updatedAt = Date()
        try? persist()
    }

    func markConnected(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastConnectedAt = Date()
        try? persist()
    }

    /// Adds or replaces the profiles of an import in one save. Their secrets are already in the Keychain. When saving
    /// fails the list stays as it was.
    func apply(_ upserts: [ConnectionProfile]) throws {
        try replace(with: BackupImportApplier.upserting(upserts, into: profiles, updatedAt: Date()))
    }

    /// Undoes an import: puts back the profiles it replaced and removes the ones it added, with their Keychain items.
    /// Profiles created or changed since stay as they are.
    func restore(_ restored: [ConnectionProfile], removing removed: [UUID]) throws {
        try replace(with: BackupImportApplier.restoring(restored, removing: removed, in: profiles))
        // Also when the import stopped before saving the profile: its secrets were written first.
        for id in Set(removed) { try? repository.deleteSecrets(of: id) }
    }

    private func replace(with updated: [ConnectionProfile]) throws {
        let previous = profiles
        profiles = updated
        do {
            try persist()
        } catch {
            profiles = previous
            throw error
        }
    }

    func password(for profile: ConnectionProfile) -> String? { repository.password(for: profile) }
    func sshSecret(for profile: ConnectionProfile) -> String? { repository.sshSecret(for: profile) }

    private func persist() throws {
        do {
            try repository.save(profiles)
            lastError = nil
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
            throw error
        }
    }
}

/// App-wide services shared by every window.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let profiles = ProfileStore()
    let historyDirectory = QueryHistoryStore.defaultDirectory
    private(set) lazy var backup = BackupCenter(stores: .live(profiles: profiles, historyDirectory: historyDirectory))
}
