//
//  Theme.swift
//  SecureVault
//
//  الهوية البصرية: "خزنة رقمية فاخرة" — ألوان داكنة هادئة، بطاقات بزوايا 16،
//  لمسات زجاجية خفيفة، وأخضر زمردي لكل ما يخص التشفير والأمان.
//

import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }

    fileprivate static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// تخزين ألوان التطبيق التي يختارها المستخدم.
enum ThemeStore {
    static let accentKey = "theme.accentHex"
    static let backgroundKey = "theme.backgroundHex"
    static let cardKey = "theme.cardHex"
    static let revisionKey = "theme.revision"

    static let defaultAccent: UInt32 = 0x3B82F6
    static let defaultBackground: UInt32 = 0x0D0F12
    static let defaultCard: UInt32 = 0x181C23

    static func value(_ key: String) -> UInt32? {
        guard let number = UserDefaults.standard.object(forKey: key) as? Int else { return nil }
        return UInt32(truncatingIfNeeded: number)
    }

    static func set(_ hex: UInt32?, for key: String) {
        if let hex {
            UserDefaults.standard.set(Int(hex), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    static func resetAll() {
        for key in [accentKey, backgroundKey, cardKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }
}

extension Color {
    /// القيمة السداسية RGB للون (يتجاهل الشفافية).
    var hexValue: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let r = UInt32(max(0, min(255, (red * 255).rounded())))
        let g = UInt32(max(0, min(255, (green * 255).rounded())))
        let b = UInt32(max(0, min(255, (blue * 255).rounded())))
        return (r << 16) | (g << 8) | b
    }
}

enum Theme {
    static let cornerRadius: CGFloat = 16

    static var accent: Color { Color(hex: ThemeStore.value(ThemeStore.accentKey) ?? ThemeStore.defaultAccent) }
    /// أخضر زمردي: التشفير والنسخ الاحتياطي.
    static let secure = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)

    static var background: Color {
        Color.dynamic(dark: ThemeStore.value(ThemeStore.backgroundKey) ?? ThemeStore.defaultBackground, light: 0xF5F7FA)
    }
    static var card: Color {
        Color.dynamic(dark: ThemeStore.value(ThemeStore.cardKey) ?? ThemeStore.defaultCard, light: 0xFFFFFF)
    }

    static let cardStroke = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)
    })

    static let secondaryText = Color.secondary

    /// خط ثابت العرض للبيانات التقنية (أسماء الملفات، الأحجام، الخوارزميات).
    static func mono(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced)
    }
}

// MARK: - مظهر التطبيق

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dark:   return "داكن"
        case .light:  return "فاتح"
        case .system: return "حسب النظام"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return nil
        }
    }

    static let storageKey = "settings.appearance"
}

// MARK: - البطاقة

struct VaultCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func vaultCard(padding: CGFloat = 16) -> some View {
        modifier(VaultCardModifier(padding: padding))
    }

    /// خلفية الشاشة الرئيسية للخزنة.
    func vaultBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - مكوّنات

/// شارة التشفير الخضراء.
struct SecureBadge: View {
    let title: LocalizedStringKey
    var systemImage: String = "lock.shield.fill"

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secure)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.secure.opacity(0.14), in: Capsule())
    }
}

/// بطاقة إحصائية صغيرة.
struct StatTile: View {
    let systemImage: String
    let value: String
    let title: LocalizedStringKey
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(verbatim: value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vaultCard(padding: 14)
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline)
            }
        }
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 360)
    }
}

struct LoadingStateView: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vaultBackground()
    }
}

/// خلفية مموهة لشاشات القفل والإعداد.
struct VaultBackdrop: View {
    var body: some View {
        ZStack {
            Theme.background

            Circle()
                .fill(Theme.accent.opacity(0.55))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -130, y: -260)

            Circle()
                .fill(Theme.secure.opacity(0.35))
                .frame(width: 280, height: 280)
                .blur(radius: 100)
                .offset(x: 150, y: 300)

            Rectangle().fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
