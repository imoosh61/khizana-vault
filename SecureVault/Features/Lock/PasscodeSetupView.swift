//
//  PasscodeSetupView.swift
//  SecureVault
//
//  إعداد رمز التطبيق (6 أرقام) عند أول تشغيل، أو تغييره من الإعدادات، عبر لوحة الأرقام الدائرية.
//

import SwiftUI

struct PasscodeSetupView: View {

    enum Mode {
        case initial
        case change
    }

    private enum Step {
        case current, new, confirm
    }

    let mode: Mode
    var onDone: (() -> Void)?

    @EnvironmentObject private var auth: BiometricAuthManager

    @State private var step: Step
    @State private var pin = ""
    @State private var currentPin = ""
    @State private var newPin = ""
    @State private var shakeTrigger = 0
    @State private var errorMessage: LocalizedStringKey?
    @State private var saveError: String?
    @State private var isWorking = false

    init(mode: Mode, onDone: (() -> Void)? = nil) {
        self.mode = mode
        self.onDone = onDone
        _step = State(initialValue: mode == .change ? .current : .new)
    }

    private var title: LocalizedStringKey {
        switch step {
        case .current: return "أدخل الرمز الحالي"
        case .new:     return "اختر رمزاً جديداً"
        case .confirm: return "أعد إدخال الرمز للتأكيد"
        }
    }

    var body: some View {
        ZStack {
            VaultBackdrop()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 16)

                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(Theme.accent)

                        if mode == .initial {
                            Text("مرحباً بك في الخزنة الآمنة")
                                .font(.title2.bold())
                            Text("سيُستخدم هذا الرمز كبديل لـ Face ID، ولا يمكن استرجاعه إن نسيته.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Text(title)
                            .font(.headline)
                            .padding(.top, 4)

                        Group {
                            if let saveError {
                                Text(verbatim: saveError)
                            } else if let errorMessage {
                                Text(errorMessage)
                            } else {
                                Text(" ")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(minHeight: 22)
                    }

                    PinPad(
                        pin: $pin,
                        length: BiometricAuthManager.pinLength,
                        isDisabled: isWorking,
                        shakeTrigger: shakeTrigger,
                        onComplete: handle
                    )

                    if isWorking { ProgressView() }

                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(mode == .initial ? Text("إعداد الرمز") : Text("تغيير الرمز"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: الخطوات

    private func handle(_ code: String) {
        errorMessage = nil
        saveError = nil

        switch step {
        case .current:
            isWorking = true
            Task {
                let valid = await auth.confirmPasscode(code)
                isWorking = false
                if valid {
                    currentPin = code
                    advance(to: .new)
                } else {
                    fail("رمز المرور غير صحيح.")
                }
            }

        case .new:
            newPin = code
            advance(to: .confirm)

        case .confirm:
            guard code == newPin else {
                newPin = ""
                step = .new
                fail("الرمزان غير متطابقين. ابدأ من جديد.")
                return
            }
            save(code)
        }
    }

    private func advance(to next: Step) {
        pin = ""
        step = next
    }

    private func fail(_ message: LocalizedStringKey) {
        pin = ""
        errorMessage = message
        shakeTrigger += 1
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func save(_ code: String) {
        isWorking = true
        let current = currentPin

        Task {
            defer { isWorking = false }
            do {
                switch mode {
                case .initial:
                    try await auth.completeInitialSetup(passcode: code)
                case .change:
                    try await auth.changePasscode(current: current, new: code)
                }
                onDone?()
            } catch {
                pin = ""
                newPin = ""
                step = .new
                saveError = error.localizedDescription
                shakeTrigger += 1
            }
        }
    }
}
