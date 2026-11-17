//
//  LockScreenView.swift
//  SecureVault
//
//  شاشة القفل: خلفية مموهة تحجب المحتوى، أيقونة Face ID تفاعلية، ولوحة أرقام دائرية كبديل.
//

import SwiftUI

struct LockScreenView: View {

    @EnvironmentObject private var auth: BiometricAuthManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var pin = ""
    @State private var shakeTrigger = 0
    @State private var secondsRemaining = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            VaultBackdrop()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 24)

                    header
                    statusLine

                    PinPad(
                        pin: $pin,
                        length: BiometricAuthManager.pinLength,
                        isDisabled: auth.isLockedOut || auth.state == .authenticating,
                        shakeTrigger: shakeTrigger,
                        biometricSystemImage: auth.canUseBiometrics ? auth.biometryKind.systemImageName : nil,
                        onBiometric: { Task { await auth.authenticateWithBiometrics() } },
                        onComplete: submit
                    )

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            updateCountdown()
            promptBiometricsIfNeeded()
        }
        .onChange(of: scenePhase) { _ in promptBiometricsIfNeeded() }
        .onChange(of: auth.needsBiometricPrompt) { _ in promptBiometricsIfNeeded() }
        .onReceive(timer) { _ in
            auth.refreshLockoutStateIfNeeded()
            updateCountdown()
        }
    }

    // MARK: الأجزاء

    private var header: some View {
        VStack(spacing: 14) {
            Button {
                Task { await auth.authenticateWithBiometrics() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 96, height: 96)
                        .overlay(Circle().strokeBorder(Theme.cardStroke, lineWidth: 1))
                    Image(systemName: auth.canUseBiometrics ? auth.biometryKind.systemImageName : "lock.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(!auth.canUseBiometrics || auth.isLockedOut)
            .accessibilityLabel(Text("فتح بالبصمة"))

            Text("الخزنة الآمنة")
                .font(.title.bold())

            SecureBadge(title: "مشفّرة ومحمية")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if auth.isLockedOut {
                Label {
                    Text("الإيقاف المؤقت: \(secondsRemaining) ثانية")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .foregroundStyle(Theme.warning)
            } else if let message = auth.lastError?.errorDescription {
                Text(verbatim: message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else {
                Text("أدخل رمز التطبيق")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(minHeight: 24)
    }

    // MARK: الإجراءات

    private func submit(_ code: String) {
        Task {
            let success = await auth.authenticateWithPasscode(code)
            if !success {
                pin = ""
                shakeTrigger += 1
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func promptBiometricsIfNeeded() {
        guard scenePhase == .active,
              auth.needsBiometricPrompt,
              auth.state == .locked,
              auth.canUseBiometrics,
              !auth.isLockedOut
        else { return }

        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard scenePhase == .active, auth.needsBiometricPrompt else { return }
            await auth.authenticateWithBiometrics()
        }
    }

    private func updateCountdown() {
        if let end = auth.lockoutEndsAt {
            secondsRemaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        } else {
            secondsRemaining = 0
        }
    }
}
