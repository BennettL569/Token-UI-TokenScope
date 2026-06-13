import SwiftUI

extension Color {
    static let scopeBackgroundLight = Color(red: 0.94, green: 0.975, blue: 1.0)
    static let scopeBackgroundDark = Color(red: 0.025, green: 0.035, blue: 0.065)
    static let scopeSurfaceLight = Color.white.opacity(0.78)
    static let scopeSurfaceDark = Color.white.opacity(0.075)
    static let neonCyan = Color(red: 0.00, green: 0.62, blue: 0.76)
    static let neonBlue = Color(red: 0.13, green: 0.34, blue: 0.95)
    static let neonPurple = Color(red: 0.56, green: 0.20, blue: 0.88)
    static let scopeTextMuted = Color(red: 0.25, green: 0.32, blue: 0.43).opacity(0.82)
}

struct ScopeTheme {
    let scheme: ColorScheme

    var backgroundGradient: LinearGradient {
        if scheme == .dark {
            return LinearGradient(colors: [.scopeBackgroundDark, Color(red: 0.04, green: 0.025, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [.scopeBackgroundLight, Color(red: 0.985, green: 0.95, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var sidebarBackground: Color {
        scheme == .dark ? Color.black.opacity(0.35) : Color(red: 0.90, green: 0.96, blue: 1.0).opacity(0.62)
    }

    var textMuted: Color {
        scheme == .dark ? Color.white.opacity(0.68) : Color(red: 0.25, green: 0.32, blue: 0.43).opacity(0.82)
    }

    var secondaryText: Color {
        scheme == .dark ? Color.white.opacity(0.62) : Color(red: 0.18, green: 0.24, blue: 0.34).opacity(0.72)
    }

    var panelFill: Color {
        scheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.78)
    }

    var panelBorder: LinearGradient {
        LinearGradient(colors: [.neonCyan.opacity(0.32), .neonPurple.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var panelShadow: Color {
        scheme == .dark ? Color.neonBlue.opacity(0.05) : Color.neonBlue.opacity(0.08)
    }

    var radialGlow: RadialGradient {
        let color = scheme == .dark ? Color.neonBlue.opacity(0.08) : Color.neonCyan.opacity(0.10)
        return RadialGradient(colors: [color, .clear], center: .topTrailing, startRadius: 40, endRadius: 500)
    }
}

private struct ScopeThemeKey: EnvironmentKey {
    static let defaultValue = ScopeTheme(scheme: .light)
}

extension EnvironmentValues {
    var scopeTheme: ScopeTheme {
        get { self[ScopeThemeKey.self] }
        set { self[ScopeThemeKey.self] = newValue }
    }
}

struct ScopeThemeReader<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.scopeTheme, ScopeTheme(scheme: colorScheme))
    }
}

struct GlassPanel<Content: View>: View {
    @Environment(\.scopeTheme) private var theme
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(theme.panelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.panelBorder, lineWidth: 1)
            )
            .shadow(color: theme.panelShadow, radius: 6, x: 0, y: 3)
    }
}

struct MetricCard: View {
    @Environment(\.scopeTheme) private var theme
    let title: String
    let value: String
    let subtitle: String
    let accent: Color
    var hint: String? = nil

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                    if hint != nil {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(theme.textMuted)
                    }
                }
                .help(hint ?? "")
                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
