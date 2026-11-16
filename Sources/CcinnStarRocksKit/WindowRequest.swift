import Foundation

/// Asks for a new window that connects to a saved connection right away. Every window has its own connection;
/// the nonce makes each request unique, because SwiftUI brings an existing window to the front instead of opening
/// a new one when the requested value is equal.
public struct WindowRequest: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var nonce: UUID

    public init(profileID: UUID) {
        self.profileID = profileID
        nonce = UUID()
    }

    private enum CodingKeys: String, CodingKey { case profileID, nonce }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        nonce = try container.decodeIfPresent(UUID.self, forKey: .nonce) ?? UUID()
    }
}
