//
//  ThemeSettingsSection.swift
//  SecureVault
//
//  تخصيص الألوان: لون التمييز، لون الخلفية، لون البطاقات (للوضع الداكن)، مع ألوان جاهزة.
//

import SwiftUI

struct ThemeSettingsSection: View {

    @AppStorage(ThemeStore.revisionKey) private var revision = 0

    private struct Preset: Identifiable {
        let id: UInt32
        var hex: UInt32 { id }
    }

    private struct BackgroundPreset: Identifiable {
        let background: UInt32
        let card: UInt32
        var id: UInt32 { background }
    }

    private let accentPresets: [Preset] = [
        0x3B82F6, 0x00A8E8, 0x10B981, 0x8B5CF6, 0xEC4899, 0xF59E0B, 0xEF4444, 0x14B8A6
    ].map { Preset(id: $0) }

    private let backgroundPresets: [BackgroundPreset] = [
        BackgroundPreset(background: 0x0D0F12, card: 0x181C23),   // منتصف الليل (الافتراضي)
        BackgroundPreset(background: 0x000000, card: 0x1C1C1E),   // أسود
        BackgroundPreset(background: 0x0A1628, card: 0x13233B),   // محيط
        BackgroundPreset(background: 0x0B1511, card: 0x14231C),   // غابة
        BackgroundPreset(background: 0x140E1C, card: 0x21172D),   // بنفسجي
        BackgroundPreset(background: 0x1A1210, card: 0x2A1E1A)    // قهوة
    ]

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Theme.accent },
            set: { ThemeStore.set($0.hexValue, for: ThemeStore.accentKey) }
        )
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(hex: ThemeStore.value(ThemeStore.backgroundKey) ?? ThemeStore.defaultBackground) },
            set: { ThemeStore.set($0.hexValue, for: ThemeStore.backgroundKey) }
        )
    }

    private var cardBinding: Binding<Color> {
        Binding(
            get: { Color(hex: ThemeStore.value(ThemeStore.cardKey) ?? ThemeStore.defaultCard) },
            set: { ThemeStore.set($0.hexValue, for: ThemeStore.cardKey) }
        )
    }

    var body: some View {
        Section {
            ColorPicker(selection: accentBinding, supportsOpacity: false) {
                Label("لون التمييز", systemImage: "paintpalette.fill")
            }

            swatchRow(accentPresets.map { $0.hex }) { hex in
                ThemeStore.set(hex, for: ThemeStore.accentKey)
            }

            ColorPicker(selection: backgroundBinding, supportsOpacity: false) {
                Label("لون الخلفية (الوضع الداكن)", systemImage: "rectangle.fill")
            }

            ColorPicker(selection: cardBinding, supportsOpacity: false) {
                Label("لون البطاقات (الوضع الداكن)", systemImage: "rectangle.on.rectangle")
            }

            swatchRow(backgroundPresets.map { $0.background }) { hex in
                guard let preset = backgroundPresets.first(where: { $0.background == hex }) else { return }
                ThemeStore.set(preset.background, for: ThemeStore.backgroundKey)
                ThemeStore.set(preset.card, for: ThemeStore.cardKey)
            }

            Button(role: .destructive) {
                ThemeStore.resetAll()
            } label: {
                Label("إعادة الألوان الافتراضية", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("الألوان")
        } footer: {
            Text("تُطبَّق الألوان فوراً. لون الخلفية والبطاقات يخصّان الوضع الداكن.")
        }
        .listRowBackground(Theme.card)
    }

    private func swatchRow(_ colors: [UInt32], onSelect: @escaping (UInt32) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(colors, id: \.self) { hex in
                    Button {
                        onSelect(hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: String(format: "#%06X", hex)))
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - تقرير آخر عطل

struct CrashReportSection: View {

    @State private var report: String? = CrashReporter.lastReport()

    var body: some View {
        if let report, !report.isEmpty {
            Section {
                ShareLink(item: report) {
                    Label("مشاركة تقرير آخر عطل", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    CrashReporter.clear()
                    self.report = nil
                } label: {
                    Label("حذف التقرير", systemImage: "trash")
                }
            } header: {
                Text("تشخيص")
            } footer: {
                Text("حدث عطل في الجلسة السابقة. التقرير محلي ولا يُرسل لأي جهة.")
            }
            .listRowBackground(Theme.card)
        }
    }
}
