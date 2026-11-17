//
//  PinPad.swift
//  SecureVault
//
//  لوحة أرقام دائرية لإدخال رمز المرور (6 خانات) مع مؤشر نقاط وحركة اهتزاز عند الخطأ.
//

import SwiftUI
import UIKit

struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 10
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: amount * sin(animatableData * .pi * shakes * 2), y: 0)
        )
    }
}

struct PinPad: View {

    @Binding var pin: String
    let length: Int
    var isDisabled = false
    /// يزداد عند كل خطأ لتشغيل حركة الاهتزاز.
    var shakeTrigger = 0
    var biometricSystemImage: String?
    var onBiometric: (() -> Void)?
    var onComplete: (String) -> Void

    private let rows: [[Int]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]

    var body: some View {
        VStack(spacing: 32) {
            dots

            VStack(spacing: 16) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 22) {
                        ForEach(row, id: \.self) { digit in
                            digitButton(digit)
                        }
                    }
                }

                HStack(spacing: 22) {
                    if let biometricSystemImage, let onBiometric {
                        Button(action: onBiometric) {
                            Image(systemName: biometricSystemImage)
                                .font(.system(size: 28))
                                .frame(width: 76, height: 76)
                        }
                        .accessibilityLabel(Text("فتح بالبصمة"))
                    } else {
                        Color.clear.frame(width: 76, height: 76)
                    }

                    digitButton(0)

                    Button {
                        guard !pin.isEmpty else { return }
                        pin.removeLast()
                        haptic(.light)
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: 24))
                            .frame(width: 76, height: 76)
                    }
                    .opacity(pin.isEmpty ? 0.35 : 1)
                    .accessibilityLabel(Text("حذف"))
                }
            }
            // اللوحة تبقى بترتيب 1-2-3 حتى في اللغات من اليمين لليسار.
            .environment(\.layoutDirection, .leftToRight)
        }
        .foregroundStyle(.primary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<length, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? Theme.accent : Color.clear)
                    .overlay(Circle().strokeBorder(index < pin.count ? Theme.accent : Color.secondary.opacity(0.6), lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .scaleEffect(index < pin.count ? 1.15 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pin.count)
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
        .animation(.linear(duration: 0.45), value: shakeTrigger)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            guard pin.count < length else { return }
            pin.append(String(digit))
            haptic(.light)
            if pin.count == length {
                onComplete(pin)
            }
        } label: {
            Text(verbatim: String(digit))
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .frame(width: 76, height: 76)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(PinKeyStyle())
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

private struct PinKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
