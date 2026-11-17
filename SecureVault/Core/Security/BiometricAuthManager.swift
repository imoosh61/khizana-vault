//
//  BiometricAuthManager.swift
//  SecureVault
//
//  قفل التطبيق: Face ID / Touch ID مع رمز مرور احتياطي خاص بالتطبيق.
//

import Foundation
import LocalAuthentication
import CryptoKit

// MARK: - مخزن Keychain

/// غلاف خفيف حول Keychain لحفظ أسرار صغيرة (ملح + مُتحقق رمز المرور).
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` فلا تُنقل عبر النسخ الاحتياطي أو iCloud.
struct KeychainStore: Sendable {

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversionFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "غير معروف")
                return String(localized: "خطأ في سلسلة المفاتيح (\(Int(status))): \(message)")
            case .dataConversionFailed:
                return String(localized: "تعذّر تحويل البيانات المخزّنة.")
            }
        }
    }

    let service: String

    init(service: String = "com.securevault.auth") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.dataConversionFailed }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func exists(account: String) -> Bool {
        guard let data = try? read(account: account) else { return false }
        return !data.isEmpty
    }
}

// MARK: - أخطاء المصادقة

enum AuthError: LocalizedError, Equatable {
    case biometryUnavailable
    case biometryNotEnrolled
    case biometryLockout
    case userCancelled
    case passcodeNotConfigured
    case passcodeIncorrect(remainingAttempts: Int)
    case temporarilyLockedOut(until: Date)
    case passcodeTooWeak
    case keychainFailure(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .biometryUnavailable:
            return String(localized: "المصادقة الحيوية غير متاحة على هذا الجهاز.")
        case .biometryNotEnrolled:
            return String(localized: "لم يتم تسجيل بصمة أو وجه على هذا الجهاز. استخدم رمز التطبيق.")
        case .biometryLockout:
            return String(localized: "تم تعطيل المصادقة الحيوية بعد محاولات فاشلة متكررة. استخدم رمز التطبيق.")
        case .userCancelled:
            return nil
        case .passcodeNotConfigured:
            return String(localized: "لم يتم ضبط رمز مرور للتطبيق بعد.")
        case .passcodeIncorrect(let remaining):
            return remaining > 0
                ? String(localized: "رمز المرور غير صحيح. المحاولات المتبقية: \(remaining).")
                : String(localized: "رمز المرور غير صحيح.")
        case .temporarilyLockedOut(let until):
            let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            return String(localized: "تم الإيقاف مؤقتاً بسبب المحاولات الفاشلة. أعد المحاولة بعد \(seconds) ثانية.")
        case .passcodeTooWeak:
            return String(localized: "رمز المرور يجب أن يتكوّن من 6 أرقام.")
        case .keychainFailure(let message):
            return String(localized: "فشل الوصول إلى سلسلة المفاتيح: \(message)")
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - المدير

@MainActor
final class BiometricAuthManager: ObservableObject {

    enum State: Equatable {
        case locked
        case authenticating
        case unlocked
    }

    enum BiometryKind: Equatable {
        case none, touchID, faceID, opticID

        var displayName: String {
            switch self {
            case .none:    return String(localized: "غير متاح")
            case .touchID: return "Touch ID"
            case .faceID:  return "Face ID"
            case .opticID: return "Optic ID"
            }
        }

        var systemImageName: String {
            switch self {
            case .none:    return "lock.fill"
            case .touchID: return "touchid"
            case .faceID:  return "faceid"
            case .opticID: return "opticid"
            }
        }
    }

    // MARK: الحالة

    @Published private(set) var state: State = .locked
    @Published private(set) var lastError: AuthError?
    @Published private(set) var failedAttempts: Int
    @Published private(set) var lockoutEndsAt: Date?
    @Published private(set) var biometryKind: BiometryKind = .none
    @Published private(set) var isPasscodeConfigured: Bool = false

    /// تُضبط عند الحاجة لعرض نافذة Face ID تلقائياً على شاشة القفل.
    @Published var needsBiometricPrompt: Bool = true

    /// مهلة القفل التلقائي بعد مغادرة التطبيق (ثوانٍ). 0 = فوراً.
    @Published var autoLockInterval: TimeInterval {
        didSet { UserDefaults.standard.set(autoLockInterval, forKey: Keys.autoLockInterval) }
    }

    @Published var isBiometricsEnabled: Bool {
        didSet { UserDefaults.standard.set(isBiometricsEnabled, forKey: Keys.biometricsEnabled) }
    }

    var isLockedOut: Bool {
        guard let lockoutEndsAt else { return false }
        return lockoutEndsAt > Date()
    }

    var canUseBiometrics: Bool {
        isBiometricsEnabled && biometryKind != .none
    }

    // MARK: الثوابت

    private enum Keys {
        static let passcodeSalt = "passcode.salt"
        static let passcodeVerifier = "passcode.verifier"
        static let biometricsEnabled = "settings.biometricsEnabled"
        static let autoLockInterval = "settings.autoLockInterval"
        static let failedAttempts = "auth.failedAttempts"
        static let lockoutEndsAt = "auth.lockoutEndsAt"
    }

    /// طول رمز التطبيق (أرقام فقط) لتوافق لوحة الأرقام الدائرية.
    nonisolated static let pinLength = 6

    private static let maxAttemptsBeforeLockout = 5
    private static let baseLockoutDuration: TimeInterval = 30
    private static let maxLockoutDuration: TimeInterval = 15 * 60

    private let keychain: KeychainStore
    private var backgroundedAt: Date?

    // MARK: التهيئة

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Keys.biometricsEnabled) == nil {
            defaults.set(true, forKey: Keys.biometricsEnabled)
        }
        if defaults.object(forKey: Keys.autoLockInterval) == nil {
            defaults.set(30.0, forKey: Keys.autoLockInterval)
        }

        self.isBiometricsEnabled = defaults.bool(forKey: Keys.biometricsEnabled)
        self.autoLockInterval = defaults.double(forKey: Keys.autoLockInterval)

        // نحفظ عدّاد المحاولات خارج الذاكرة حتى لا يُصفَّر بإعادة تشغيل التطبيق.
        self.failedAttempts = defaults.integer(forKey: Keys.failedAttempts)
        let storedLockout = defaults.double(forKey: Keys.lockoutEndsAt)
        self.lockoutEndsAt = storedLockout > 0 ? Date(timeIntervalSince1970: storedLockout) : nil

        self.isPasscodeConfigured =
            keychain.exists(account: Keys.passcodeVerifier) && keychain.exists(account: Keys.passcodeSalt)

        refreshBiometryKind()
    }

    // MARK: قدرات الجهاز

    func refreshBiometryKind() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            biometryKind = .none
            return
        }
        switch context.biometryType {
        case .faceID:  biometryKind = .faceID
        case .touchID: biometryKind = .touchID
        default:
            // Optic ID غير مدعوم على iPhone/iPad.
            biometryKind = .none
        }
    }

    // MARK: المصادقة الحيوية

    @discardableResult
    func authenticateWithBiometrics(
        reason: String = String(localized: "افتح الخزنة الآمنة للوصول إلى بياناتك")
    ) async -> Bool {

        needsBiometricPrompt = false

        guard state != .unlocked else { return true }

        guard !isLockedOut else {
            lastError = .temporarilyLockedOut(until: lockoutEndsAt ?? Date())
            return false
        }

        guard canUseBiometrics else {
            lastError = isBiometricsEnabled ? .biometryUnavailable : nil
            return false
        }

        let context = LAContext()
        context.localizedFallbackTitle = isPasscodeConfigured ? String(localized: "استخدام رمز التطبيق") : ""
        context.localizedCancelTitle = String(localized: "إلغاء")

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            lastError = Self.mapLAError(policyError)
            return false
        }

        state = .authenticating
        lastError = nil

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if success {
                unlock()
                return true
            }
            state = .locked
            lastError = .unknown("فشلت المصادقة لسبب غير معروف.")
            return false
        } catch {
            state = .locked
            let mapped = Self.mapLAError(error as NSError)
            lastError = (mapped == .userCancelled) ? nil : mapped
            return false
        }
    }

    // MARK: رمز المرور

    /// الإعداد الأول: يضبط الرمز ويفتح القفل مباشرة.
    func completeInitialSetup(passcode: String) async throws {
        try await setPasscode(passcode)
        unlock()
    }

    func setPasscode(_ passcode: String) async throws {
        let normalized = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == Self.pinLength, normalized.allSatisfy(\.isNumber) else {
            throw AuthError.passcodeTooWeak
        }

        let salt = EncryptionManager.randomSalt()
        let verifier = try await Task.detached(priority: .userInitiated) {
            try EncryptionManager.derivePasscodeVerifier(passcode: normalized, salt: salt)
        }.value

        do {
            try keychain.save(salt, account: Keys.passcodeSalt)
            try keychain.save(verifier, account: Keys.passcodeVerifier)
        } catch {
            throw AuthError.keychainFailure(error.localizedDescription)
        }

        isPasscodeConfigured = true
        resetAttempts()
    }

    func changePasscode(current: String, new: String) async throws {
        guard try await verifyPasscodeSilently(current) else {
            throw AuthError.passcodeIncorrect(remainingAttempts: remainingAttempts())
        }
        try await setPasscode(new)
    }

    /// يتحقق من الرمز الحالي دون تغيير حالة القفل (للعمليات الحساسة داخل الإعدادات).
    func confirmPasscode(_ passcode: String) async -> Bool {
        (try? await verifyPasscodeSilently(passcode)) ?? false
    }

    @discardableResult
    func authenticateWithPasscode(_ passcode: String) async -> Bool {

        guard !isLockedOut else {
            lastError = .temporarilyLockedOut(until: lockoutEndsAt ?? Date())
            return false
        }
        guard isPasscodeConfigured else {
            lastError = .passcodeNotConfigured
            return false
        }

        state = .authenticating

        do {
            if try await verifyPasscodeSilently(passcode) {
                unlock()
                return true
            }
        } catch {
            state = .locked
            lastError = .keychainFailure(error.localizedDescription)
            return false
        }

        state = .locked
        registerFailedAttempt()
        return false
    }

    private func verifyPasscodeSilently(_ passcode: String) async throws -> Bool {
        let salt: Data
        let stored: Data
        do {
            guard
                let s = try keychain.read(account: Keys.passcodeSalt),
                let v = try keychain.read(account: Keys.passcodeVerifier)
            else { throw AuthError.passcodeNotConfigured }
            salt = s
            stored = v
        }

        let normalized = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = try await Task.detached(priority: .userInitiated) {
            try EncryptionManager.derivePasscodeVerifier(passcode: normalized, salt: salt)
        }.value

        return Self.constantTimeEquals(candidate, stored)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    // MARK: المحاولات والإيقاف المؤقت

    private func remainingAttempts() -> Int {
        max(0, Self.maxAttemptsBeforeLockout - failedAttempts)
    }

    private func registerFailedAttempt() {
        failedAttempts += 1
        UserDefaults.standard.set(failedAttempts, forKey: Keys.failedAttempts)

        if failedAttempts >= Self.maxAttemptsBeforeLockout {
            // تصاعد أُسّي: 30ث، 60ث، 120ث ... حتى 15 دقيقة.
            let overflow = failedAttempts - Self.maxAttemptsBeforeLockout
            let duration = min(Self.baseLockoutDuration * pow(2, Double(overflow)), Self.maxLockoutDuration)
            let until = Date().addingTimeInterval(duration)
            lockoutEndsAt = until
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Keys.lockoutEndsAt)
            lastError = .temporarilyLockedOut(until: until)
        } else {
            lastError = .passcodeIncorrect(remainingAttempts: remainingAttempts())
        }
    }

    private func resetAttempts() {
        failedAttempts = 0
        lockoutEndsAt = nil
        UserDefaults.standard.set(0, forKey: Keys.failedAttempts)
        UserDefaults.standard.removeObject(forKey: Keys.lockoutEndsAt)
    }

    /// يُستدعى من مؤقّت واجهة القفل. ينهي الإيقاف المؤقت دون تصفير العدّاد
    /// (كي يتصاعد الإيقاف عند استمرار الفشل).
    func refreshLockoutStateIfNeeded() {
        guard let end = lockoutEndsAt, end <= Date() else { return }
        lockoutEndsAt = nil
        UserDefaults.standard.removeObject(forKey: Keys.lockoutEndsAt)
        if case .temporarilyLockedOut = lastError { lastError = nil }
    }

    // MARK: دورة حياة القفل

    private func unlock() {
        state = .unlocked
        lastError = nil
        resetAttempts()
        backgroundedAt = nil
    }

    func lock() {
        state = .locked
        backgroundedAt = nil
        needsBiometricPrompt = true
    }

    func applicationDidEnterBackground() {
        backgroundedAt = Date()
    }

    func applicationWillEnterForeground() {
        refreshBiometryKind()
        refreshLockoutStateIfNeeded()

        guard state == .unlocked, let backgroundedAt else { return }
        if Date().timeIntervalSince(backgroundedAt) >= autoLockInterval {
            lock()
        }
        self.backgroundedAt = nil
    }

    func clearError() { lastError = nil }

    // MARK: تحويل أخطاء LocalAuthentication

    private static func mapLAError(_ error: NSError?) -> AuthError {
        guard let error else { return .unknown("خطأ غير معروف في المصادقة.") }

        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .userCancelled
        case .biometryNotAvailable:
            return .biometryUnavailable
        case .biometryNotEnrolled:
            return .biometryNotEnrolled
        case .biometryLockout:
            return .biometryLockout
        case .authenticationFailed:
            return .unknown("لم يتم التعرف عليك. حاول مرة أخرى.")
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
