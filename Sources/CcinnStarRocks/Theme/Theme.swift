import AppKit
import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

/// Visual language: one accent ("nebula indigo"), adaptive syntax palette, consistent metrics, and
/// a distinct icon + colour for every StarRocks object kind and table model.
enum Theme {
    static let accent = Color(nsColor: .appAccent)

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let smallCornerRadius: CGFloat = 6
        static let cardPadding: CGFloat = 14
    }

    static let monospaced = Font.system(size: 12, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    static func color(for profileColor: ProfileColor) -> Color {
        switch profileColor {
        case .none: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    // MARK: Object kinds

    static func icon(for kind: ObjectKind) -> String {
        switch kind {
        case .table: "tablecells"
        case .asyncMaterializedView: "square.stack.3d.up.fill"
        case .syncMaterializedView: "square.stack.3d.down.right"
        case .view: "eye"
        case .externalTable: "externaldrive.connected.to.line.below"
        case .systemView: "gearshape"
        }
    }

    static func color(for kind: ObjectKind) -> Color {
        switch kind {
        case .table: Color(nsColor: .kindTable)
        case .asyncMaterializedView: Color(nsColor: .kindAsyncMV)
        case .syncMaterializedView: Color(nsColor: .kindSyncMV)
        case .view: Color(nsColor: .kindView)
        case .externalTable: Color(nsColor: .kindExternal)
        case .systemView: .secondary
        }
    }

    static func color(for model: TableModel) -> Color {
        switch model {
        case .duplicate: Color(nsColor: .adaptive(light: .hex(0x5B6472), dark: .hex(0xA3ACBA)))
        case .aggregate: Color(nsColor: .adaptive(light: .hex(0xB45309), dark: .hex(0xFBBF5A)))
        case .unique: Color(nsColor: .adaptive(light: .hex(0x0F766E), dark: .hex(0x5EEAD4)))
        case .primary: Color(nsColor: .adaptive(light: .hex(0x4338CA), dark: .hex(0xA5B4FC)))
        }
    }

    static func color(for health: MaterializedViewStatus.Health) -> Color {
        switch health {
        case .healthy: .green
        case .refreshing: .blue
        case .failed: .red
        case .inactive: .orange
        case .neverRefreshed: .secondary
        case .maintainedSynchronously: .teal
        }
    }

    static func label(for health: MaterializedViewStatus.Health) -> String {
        switch health {
        case .healthy: "Up to date"
        case .refreshing: "Refreshing"
        case .failed: "Last refresh failed"
        case .inactive: "Inactive"
        case .neverRefreshed: "Not refreshed yet"
        case .maintainedSynchronously: "Maintained with base table"
        }
    }

    /// Colour for job/task/load states reported by StarRocks.
    static func color(forState state: String) -> Color {
        switch state.uppercased() {
        case "SUCCESS", "FINISHED", "NORMAL", "MERGED", "SKIPPED": .green
        case "RUNNING", "LOADING", "ETL", "COMMITTED", "PREPARED", "WAITING_TXN", "NEED_SCHEDULE": .blue
        case "PENDING", "QUEUEING", "PAUSED": .orange
        case "FAILED", "CANCELLED", "STOPPED", "ERROR": .red
        default: .secondary
        }
    }
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let appAccent = adaptive(light: .hex(0x4F46E5), dark: .hex(0x8B93FF))

    static let kindTable = adaptive(light: .hex(0x2563EB), dark: .hex(0x60A5FA))
    static let kindAsyncMV = adaptive(light: .hex(0x9333EA), dark: .hex(0xC084FC))
    static let kindSyncMV = adaptive(light: .hex(0x0D9488), dark: .hex(0x2DD4BF))
    static let kindView = adaptive(light: .hex(0xD97706), dark: .hex(0xFBBF24))
    static let kindExternal = adaptive(light: .hex(0x64748B), dark: .hex(0x94A3B8))

    static let syntaxKeyword = adaptive(light: .hex(0x7C3AED), dark: .hex(0xC4A1FF))
    static let syntaxFunction = adaptive(light: .hex(0x0369A1), dark: .hex(0x7DD3FC))
    static let syntaxString = adaptive(light: .hex(0x15803D), dark: .hex(0x86EFAC))
    static let syntaxNumber = adaptive(light: .hex(0xC2410C), dark: .hex(0xFDBA74))
    static let syntaxComment = adaptive(light: .hex(0x8A8F98), dark: .hex(0x6B7280))
    static let syntaxQuoted = adaptive(light: .hex(0xA16207), dark: .hex(0xFDE68A))
    static let syntaxVariable = adaptive(light: .hex(0xBE185D), dark: .hex(0xF9A8D4))
    static let currentStatement = adaptive(light: NSColor.hex(0x4F46E5).withAlphaComponent(0.05),
                                           dark: NSColor.hex(0x8B93FF).withAlphaComponent(0.08))
    static let nullValue = NSColor.tertiaryLabelColor
}

enum Format {
    /// Trap-free Double → Int64 (NaN/±inf/out-of-range values are clamped).
    static func int64(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        if value >= 9.223_372_036_854_775e18 { return .max }
        if value <= -9.223_372_036_854_775e18 { return .min }
        return Int64(value)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        guard value > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func duration(milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "—" }
        if milliseconds < 1 { return "<1 ms" }
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
        if milliseconds < 60_000 { return String(format: "%.2f s", milliseconds / 1000) }
        let seconds = int64(milliseconds / 1000)
        if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds % 86_400 / 3600)h" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func duration(seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return duration(milliseconds: seconds * 1000)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }
}

/// Small rounded label used for versions, models and states.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Model badge (DUP / AGG / UNI / PK).
struct ModelBadge: View {
    let model: TableModel

    var body: some View {
        Text(model.badge)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(Theme.color(for: model))
            .background(Theme.color(for: model).opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
            .help(model.displayName + " model")
            .fixedSize()
    }
}

/// Icon for a catalog object, with a health dot for async MVs.
struct ObjectIcon: View {
    let kind: ObjectKind
    var health: MaterializedViewStatus.Health?

    var body: some View {
        Image(systemName: Theme.icon(for: kind))
            .foregroundStyle(Theme.color(for: kind))
            .frame(width: 18)
            .overlay(alignment: .bottomTrailing) {
                if kind == .asyncMaterializedView, let health, health != .healthy {
                    Circle()
                        .fill(Theme.color(for: health))
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
            }
    }
}

/// State label coloured by StarRocks job state.
struct StateBadge: View {
    let state: String

    var body: some View {
        Badge(text: state.uppercased(), color: Theme.color(forState: state))
    }
}

/// Inline error presentation with a copy affordance.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Pasteboard.copy(message)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy error")
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(Color.red.opacity(0.25)))
    }
}

/// Informational (non-error) notice, e.g. missing privileges.
struct NoticeBanner: View {
    let message: String
    var systemImage = "info.circle"
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(message).font(.callout).textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
    }
}

/// Card container used across the app.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "square")
                    .labelStyle(TitleOnlyIfNoIcon(hasIcon: systemImage != nil))
                    .font(.headline)
            }
            content
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

private struct TitleOnlyIfNoIcon: LabelStyle {
    let hasIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        if hasIcon {
            HStack(spacing: 6) {
                configuration.icon.foregroundStyle(Theme.accent)
                configuration.title
            }
        } else {
            configuration.title
        }
    }
}

/// Big number with a caption, used in summary rows.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Two-column key/value list.
struct KeyValueList: View {
    let items: [(String, String)]
    var monospacedValues = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(item.1)
                        .font(monospacedValues ? Theme.monospacedSmall : .body)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .font(.callout)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The app mark, drawn in SwiftUI so it matches the generated app icon.
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.96), Color(red: 0.16, green: 0.12, blue: 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white.gradient)
                .offset(y: -size * 0.06)
                .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: size * 0.5, height: size * 0.07)
                .offset(y: size * 0.27)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.04)
    }
}
