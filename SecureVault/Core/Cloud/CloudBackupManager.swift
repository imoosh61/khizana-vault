//
//  CloudBackupManager.swift
//  SecureVault
//
//  خط أنابيب النسخ الاحتياطي:
//    حفظ القاعدة → تجميع (staging) → أرشفة AppleArchive → تشفير AES-GCM → رفع Google Drive
//  والاستعادة بالعكس. تُجهَّز النسخة المستعادة في مجلد معلّق ثم تُطبَّق عبر `AppEnvironment`
//  بعد فصل قاعدة البيانات المفتوحة.
//

import Foundation
import CoreData
import AppleArchive
import System
import UIKit
import GoogleSignIn

// MARK: - الأخطاء

enum BackupError: LocalizedError {
    case notSignedIn
    case googleNotConfigured
    case archiveFailed(String)
    case extractionFailed(String)
    case manifestMissing
    case manifestIncompatible(Int)
    case integrityCheckFailed(String)
    case driveRequestFailed(statusCode: Int, message: String)
    case invalidResponse
    case weakPassword

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "لم يتم تسجيل الدخول إلى حساب Google.")
        case .googleNotConfigured:
            return String(localized: "لم يتم ضبط GIDClientID في Info.plist. راجع ملف README لإعداد Google Cloud.")
        case .archiveFailed(let detail):
            return String(localized: "فشل إنشاء الأرشيف: \(detail)")
        case .extractionFailed(let detail):
            return String(localized: "فشل فك الأرشيف: \(detail)")
        case .manifestMissing:
            return String(localized: "ملف بيان النسخة الاحتياطية مفقود — الملف قد يكون تالفاً.")
        case .manifestIncompatible(let version):
            return String(localized: "هذه النسخة الاحتياطية (إصدار \(version)) تتطلب إصداراً أحدث من التطبيق.")
        case .integrityCheckFailed(let fileName):
            return String(localized: "فشل التحقق من سلامة الملف: \(fileName)")
        case .driveRequestFailed(let statusCode, let message):
            return String(localized: "فشل طلب Google Drive (\(statusCode)): \(message)")
        case .invalidResponse:
            return String(localized: "استجابة غير متوقعة من الخادم.")
        case .weakPassword:
            return String(localized: "كلمة مرور النسخة الاحتياطية يجب ألا تقل عن 8 خانات.")
        }
    }
}

// MARK: - نموذج ملف Drive

struct DriveFile: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let size: String?
    let createdTime: Date?
    let mimeType: String?

    var byteCount: Int64 { Int64(size ?? "0") ?? 0 }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    /// Drive يعيد التاريخ بكسور الثواني ("...00.000Z") فلا يكفي `.iso8601` الافتراضي.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: raw) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(localized: "تاريخ غير صالح: \(raw)"))
        }
        return decoder
    }
}

private struct DriveFileList: Decodable {
    let files: [DriveFile]
}

// MARK: - تفويض الوصول

protocol DriveAuthorizing: Sendable {
    func accessToken() async throws -> String
}

/// المصادقة عبر GoogleSignIn بنطاق `drive.appdata`: مجلد مخفي خاص بالتطبيق،
/// لا يرى بقية ملفات المستخدم، وهو أقل النطاقات امتيازاً المناسب لحالتنا.
final class GoogleSignInAuthorizer: DriveAuthorizing, @unchecked Sendable {

    static let driveAppDataScope = "https://www.googleapis.com/auth/drive.appdata"

    /// يتحقق من أن GIDClientID مضبوط فعلاً (وليس القيمة الافتراضية).
    static var isConfigured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { return false }
        return !id.isEmpty && !id.contains("YOUR_CLIENT_ID")
    }

    @MainActor static var isSignedIn: Bool { GIDSignIn.sharedInstance.currentUser != nil }
    @MainActor static var userEmail: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }

    @MainActor
    static func restorePreviousSignIn() async {
        guard isConfigured, GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        _ = try? await GIDSignIn.sharedInstance.restorePreviousSignIn()
    }

    @MainActor
    static func signIn() async throws {
        guard isConfigured else { throw BackupError.googleNotConfigured }
        guard let presenter = topViewController() else { throw BackupError.notSignedIn }

        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            additionalScopes: [driveAppDataScope]
        )
        let granted = result.user.grantedScopes ?? []
        if !granted.contains(driveAppDataScope) {
            _ = try await result.user.addScopes([driveAppDataScope], presenting: presenter)
        }
    }

    @MainActor
    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    @MainActor
    func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw BackupError.notSignedIn }
        let refreshed = try await user.refreshTokensIfNeeded()
        return refreshed.accessToken.tokenString
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

// MARK: - مندوب التقدّم (للرفع)

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - منزّل الملفات (تقدّم + نقل الملف قبل حذفه من المجلد المؤقت)

private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, onProgress: (@Sendable (Double) -> Void)?) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 4
        configuration.waitsForConnectivity = true

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // الملف المؤقت يُحذف بعد عودة هذه الدالة، فننقله هنا مباشرة.
        guard let http = downloadTask.response as? HTTPURLResponse else {
            failure = BackupError.invalidResponse
            return
        }
        guard (200...299).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: location)).flatMap { String(data: $0, encoding: .utf8) } ?? String(localized: "بدون تفاصيل")
            failure = BackupError.driveRequestFailed(statusCode: http.statusCode, message: body)
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            onProgress?(1.0)
            continuation?.resume()
        }
    }
}

// MARK: - خدمة Google Drive (REST مباشر)

actor GoogleDriveService {

    private let authorizer: DriveAuthorizing
    private let session: URLSession

    private static let filesEndpoint = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let resumableUploadEndpoint =
        URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!
    private static let appDataSpace = "appDataFolder"
    private static let fileFields = "id,name,size,createdTime,mimeType"

    init(authorizer: DriveAuthorizing) {
        self.authorizer = authorizer
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 4
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    private func authorizedRequest(url: URL, method: String = "GET") async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await authorizer.accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    func listBackups() async throws -> [DriveFile] {
        var components = URLComponents(url: Self.filesEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: Self.appDataSpace),
            URLQueryItem(name: "fields", value: "files(\(Self.fileFields))"),
            URLQueryItem(name: "orderBy", value: "createdTime desc"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "q", value: "trashed = false")
        ]

        let request = try await authorizedRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try DriveFile.decoder().decode(DriveFileList.self, from: data).files
    }

    /// رفع على مرحلتين (Resumable): بدء الجلسة ثم إرسال الملف من القرص دون تحميله في الذاكرة.
    func upload(
        fileURL: URL,
        name: String,
        mimeType: String = "application/octet-stream",
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DriveFile {

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        var initRequest = try await authorizedRequest(url: Self.resumableUploadEndpoint, method: "POST")
        initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initRequest.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        initRequest.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        initRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "parents": [Self.appDataSpace],
            "mimeType": mimeType
        ] as [String: Any])

        let (initData, initResponse) = try await session.data(for: initRequest)
        try Self.validate(response: initResponse, data: initData)

        guard
            let http = initResponse as? HTTPURLResponse,
            let location = http.value(forHTTPHeaderField: "Location"),
            let sessionURL = URL(string: location)
        else { throw BackupError.invalidResponse }

        var uploadRequest = URLRequest(url: sessionURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, response) = try await session.upload(for: uploadRequest, fromFile: fileURL, delegate: delegate)
        try Self.validate(response: response, data: data)

        // استجابة الرفع لا تتضمن الحجم وتاريخ الإنشاء — نجلب البيانات الوصفية كاملة.
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        else { throw BackupError.invalidResponse }

        progress?(1.0)
        return try await metadata(for: id)
    }

    func download(
        fileID: String,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var components = URLComponents(
            url: Self.filesEndpoint.appending(path: fileID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]

        let request = try await authorizedRequest(url: components.url!)
        let downloader = FileDownloader(destination: destination, onProgress: progress)
        try await downloader.download(request: request)
    }

    func delete(fileID: String) async throws {
        let request = try await authorizedRequest(
            url: Self.filesEndpoint.appending(path: fileID),
            method: "DELETE"
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
    }

    func metadata(for fileID: String) async throws -> DriveFile {
        var components = URLComponents(
            url: Self.filesEndpoint.appending(path: fileID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "fields", value: Self.fileFields)]

        let request = try await authorizedRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try DriveFile.decoder().decode(DriveFile.self, from: data)
    }

    private static func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw BackupError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? String(localized: "بدون تفاصيل")
            throw BackupError.driveRequestFailed(statusCode: http.statusCode, message: message)
        }
    }
}

// MARK: - الأرشفة (AppleArchive)

enum VaultArchiver {

    private static let fieldKeys = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM"

    static func archiveDirectory(at sourceDirectory: URL, to destination: URL) throws {
        guard let writeStream = ArchiveByteStream.fileStream(
            path: FilePath(destination.path(percentEncoded: false)),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw BackupError.archiveFailed("تعذّر فتح ملف الأرشيف للكتابة.") }
        defer { try? writeStream.close() }

        guard let compressStream = ArchiveByteStream.compressionStream(
            using: .lzfse,
            writingTo: writeStream
        ) else { throw BackupError.archiveFailed("تعذّر تهيئة مجرى الضغط.") }
        defer { try? compressStream.close() }

        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
            throw BackupError.archiveFailed("تعذّر تهيئة مجرى الترميز.")
        }
        defer { try? encodeStream.close() }

        guard let keySet = ArchiveHeader.FieldKeySet(fieldKeys) else {
            throw BackupError.archiveFailed("مجموعة حقول الأرشيف غير صالحة.")
        }

        do {
            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(sourceDirectory.path(percentEncoded: false)),
                keySet: keySet
            )
        } catch {
            throw BackupError.archiveFailed(error.localizedDescription)
        }
    }

    static func extractArchive(at source: URL, to destinationDirectory: URL) throws {
        try VaultStorage.ensureDirectory(at: destinationDirectory, protected: true)

        guard let readStream = ArchiveByteStream.fileStream(
            path: FilePath(source.path(percentEncoded: false)),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)
        ) else { throw BackupError.extractionFailed("تعذّر فتح ملف الأرشيف للقراءة.") }
        defer { try? readStream.close() }

        guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream) else {
            throw BackupError.extractionFailed("تعذّر تهيئة مجرى فك الضغط.")
        }
        defer { try? decompressStream.close() }

        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
            throw BackupError.extractionFailed("تعذّر تهيئة مجرى فك الترميز.")
        }
        defer { try? decodeStream.close() }

        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: FilePath(destinationDirectory.path(percentEncoded: false)),
            flags: [.ignoreOperationNotPermitted]
        ) else { throw BackupError.extractionFailed("تعذّر تهيئة مجرى الاستخراج.") }
        defer { try? extractStream.close() }

        do {
            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            throw BackupError.extractionFailed(error.localizedDescription)
        }
    }
}

// MARK: - تطبيق الاستعادة

enum VaultRestore {

    private static let pendingFlagKey = "restore.pending"

    static var hasPendingRestore: Bool {
        UserDefaults.standard.bool(forKey: pendingFlagKey)
            && FileManager.default.fileExists(
                atPath: VaultStorage.pendingRestoreDirectory.path(percentEncoded: false)
            )
    }

    static func markPendingRestore() {
        UserDefaults.standard.set(true, forKey: pendingFlagKey)
    }

    /// **تُستدعى قبل إنشاء `PersistenceController`** (عند الإقلاع أو بعد فصل المخزن الحالي).
    static func applyPendingRestoreIfNeeded() throws {
        guard hasPendingRestore else { return }

        let fm = FileManager.default
        let staging = VaultStorage.pendingRestoreDirectory
        let root = VaultStorage.rootDirectory
        try VaultStorage.ensureDirectory(at: root)

        // 1) قاعدة البيانات
        let storeNames = [
            VaultStorage.storeFileName,
            "\(VaultStorage.storeFileName)-wal",
            "\(VaultStorage.storeFileName)-shm"
        ]
        for name in storeNames {
            let incoming = staging.appending(path: name, directoryHint: .notDirectory)
            let target = root.appending(path: name, directoryHint: .notDirectory)
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                try fm.removeItem(at: target)
            }
            if fm.fileExists(atPath: incoming.path(percentEncoded: false)) {
                try fm.moveItem(at: incoming, to: target)
                VaultStorage.protectFile(at: target)
            }
        }

        // 2) مجلد الوسائط
        let incomingMedia = staging.appending(path: VaultStorage.mediaDirectoryName, directoryHint: .isDirectory)
        let targetMedia = VaultStorage.mediaDirectory
        if fm.fileExists(atPath: incomingMedia.path(percentEncoded: false)) {
            if fm.fileExists(atPath: targetMedia.path(percentEncoded: false)) {
                try fm.removeItem(at: targetMedia)
            }
            try fm.moveItem(at: incomingMedia, to: targetMedia)
        }
        try VaultStorage.ensureDirectory(at: targetMedia)

        // 3) تنظيف
        try? fm.removeItem(at: staging)
        UserDefaults.standard.set(false, forKey: pendingFlagKey)
    }
}

// MARK: - المدير الرئيسي

@MainActor
final class CloudBackupManager: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case archiving
        case encrypting
        case uploading
        case downloading
        case decrypting
        case extracting
        case verifying
        case finished(message: String)
        case failed(message: String)

        var localizedTitle: String {
            switch self {
            case .idle:        return String(localized: "جاهز")
            case .preparing:   return String(localized: "تجهيز البيانات…")
            case .archiving:   return String(localized: "ضغط الملفات…")
            case .encrypting:  return String(localized: "تشفير النسخة…")
            case .uploading:   return String(localized: "الرفع إلى Google Drive…")
            case .downloading: return String(localized: "تنزيل النسخة…")
            case .decrypting:  return String(localized: "فك التشفير…")
            case .extracting:  return String(localized: "فك الضغط…")
            case .verifying:   return String(localized: "التحقق من السلامة…")
            case .finished(let message): return message
            case .failed(let message):   return message
            }
        }

        var isBusy: Bool {
            switch self {
            case .idle, .finished, .failed: return false
            default: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var availableBackups: [DriveFile] = []
    @Published private(set) var isSignedIn = false
    @Published private(set) var signedInEmail: String?
    @Published private(set) var isLoadingList = false

    private let drive: GoogleDriveService

    init() {
        self.drive = GoogleDriveService(authorizer: GoogleSignInAuthorizer())
    }

    var isGoogleConfigured: Bool { GoogleSignInAuthorizer.isConfigured }

    // MARK: الحساب

    private func syncAccountState() {
        isSignedIn = GoogleSignInAuthorizer.isSignedIn
        signedInEmail = GoogleSignInAuthorizer.userEmail
    }

    func restorePreviousSignIn() async {
        await GoogleSignInAuthorizer.restorePreviousSignIn()
        syncAccountState()
        if isSignedIn { await refreshBackupList() }
    }

    func signIn() async {
        do {
            try await GoogleSignInAuthorizer.signIn()
            syncAccountState()
            await refreshBackupList()
        } catch {
            // إلغاء المستخدم لنافذة الدخول ليس خطأً يستحق العرض.
            let nsError = error as NSError
            if nsError.domain == "com.google.GIDSignIn", nsError.code == -5 { return }
            phase = .failed(message: error.localizedDescription)
        }
    }

    func signOut() {
        GoogleSignInAuthorizer.signOut()
        availableBackups = []
        phase = .idle
        syncAccountState()
    }

    func reportFailure(_ message: String) {
        phase = .failed(message: message)
    }

    // MARK: القائمة

    func refreshBackupList() async {
        guard isSignedIn else { return }
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            availableBackups = try await drive.listBackups().filter { $0.name.hasSuffix(".enc") }
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    func deleteBackup(_ file: DriveFile) async {
        do {
            try await drive.delete(fileID: file.id)
            availableBackups.removeAll { $0.id == file.id }
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    // MARK: إنشاء نسخة

    /// - Parameter password: كلمة مرور التشفير (منفصلة عن رمز قفل التطبيق ولا تُخزَّن في أي مكان).
    @discardableResult
    func createBackup(password: String, context: NSManagedObjectContext) async -> Bool {

        guard isSignedIn else {
            phase = .failed(message: BackupError.notSignedIn.localizedDescription)
            return false
        }
        guard password.count >= 8 else {
            phase = .failed(message: BackupError.weakPassword.localizedDescription)
            return false
        }

        progress = 0
        phase = .preparing
        var scratch: URL?

        do {
            // 1) تفريغ التغييرات المعلّقة قبل نسخ ملف القاعدة.
            try context.saveIfNeeded()
            let noteCount = try context.count(for: Note.request())
            let mediaCount = try context.count(for: MediaItem.request())

            let scratchDirectory = try VaultStorage.makeScratchDirectory()
            scratch = scratchDirectory

            // 2) تجميع مرحلي.
            let stagingDirectory = scratchDirectory.appending(path: "staging", directoryHint: .isDirectory)
            try await Task.detached(priority: .userInitiated) {
                try Self.buildStagingDirectory(at: stagingDirectory, noteCount: noteCount, mediaCount: mediaCount)
            }.value

            // 3) أرشفة.
            phase = .archiving
            let archiveURL = scratchDirectory.appending(path: "payload.aar", directoryHint: .notDirectory)
            try await Task.detached(priority: .userInitiated) {
                try VaultArchiver.archiveDirectory(at: stagingDirectory, to: archiveURL)
            }.value
            try? FileManager.default.removeItem(at: stagingDirectory)

            // 4) تشفير.
            phase = .encrypting
            progress = 0
            let fileName = Self.makeBackupFileName()
            let encryptedURL = scratchDirectory.appending(path: fileName, directoryHint: .notDirectory)
            let report = progressReporter()
            try await Task.detached(priority: .userInitiated) {
                try EncryptionManager.encryptFile(at: archiveURL, to: encryptedURL, password: password, progress: report)
            }.value
            try? FileManager.default.removeItem(at: archiveURL)

            // 5) رفع.
            phase = .uploading
            progress = 0
            let uploaded = try await drive.upload(fileURL: encryptedURL, name: fileName, progress: progressReporter())

            // 6) سجل محلي.
            BackupRecord.insert(
                in: context,
                remoteFileID: uploaded.id,
                fileName: uploaded.name,
                createdAt: uploaded.createdTime ?? Date(),
                encryptedByteCount: uploaded.byteCount,
                noteCount: noteCount,
                mediaCount: mediaCount,
                deviceName: UIDevice.current.name,
                appVersion: AppInfo.version
            )
            try context.saveIfNeeded()

            try? FileManager.default.removeItem(at: scratchDirectory)
            scratch = nil

            progress = 1
            phase = .finished(message: String(localized: "تم رفع النسخة الاحتياطية المشفّرة بنجاح."))
            await refreshBackupList()
            return true

        } catch {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            phase = .failed(message: error.localizedDescription)
            return false
        }
    }

    // MARK: الاستعادة

    /// ينزّل النسخة ويفك تشفيرها ويجهّزها. بعد النجاح يجب استدعاء `AppEnvironment.reloadAfterRestore()`.
    func restoreBackup(_ file: DriveFile, password: String) async -> Bool {

        guard isSignedIn else {
            phase = .failed(message: BackupError.notSignedIn.localizedDescription)
            return false
        }

        progress = 0
        var scratch: URL?

        do {
            let scratchDirectory = try VaultStorage.makeScratchDirectory()
            scratch = scratchDirectory

            // 1) تنزيل.
            phase = .downloading
            let encryptedURL = scratchDirectory.appending(path: "download.enc", directoryHint: .notDirectory)
            try await drive.download(fileID: file.id, to: encryptedURL, progress: progressReporter())

            // 2) فك التشفير.
            phase = .decrypting
            progress = 0
            let archiveURL = scratchDirectory.appending(path: "payload.aar", directoryHint: .notDirectory)
            let report = progressReporter()
            try await Task.detached(priority: .userInitiated) {
                try EncryptionManager.decryptFile(at: encryptedURL, to: archiveURL, password: password, progress: report)
            }.value
            try? FileManager.default.removeItem(at: encryptedURL)

            // 3) فك الضغط.
            phase = .extracting
            progress = 0
            let extracted = scratchDirectory.appending(path: "extracted", directoryHint: .isDirectory)
            try await Task.detached(priority: .userInitiated) {
                try VaultArchiver.extractArchive(at: archiveURL, to: extracted)
            }.value
            try? FileManager.default.removeItem(at: archiveURL)

            // 4) تحقق.
            phase = .verifying
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyExtractedPayload(at: extracted)
            }.value

            // 5) نقل إلى المنطقة المعلّقة.
            let fm = FileManager.default
            let pending = VaultStorage.pendingRestoreDirectory
            if fm.fileExists(atPath: pending.path(percentEncoded: false)) {
                try fm.removeItem(at: pending)
            }
            try fm.moveItem(at: extracted, to: pending)
            VaultRestore.markPendingRestore()

            try? fm.removeItem(at: scratchDirectory)
            scratch = nil

            progress = 1
            phase = .finished(message: String(localized: "تمت الاستعادة بنجاح."))
            return true

        } catch {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            phase = .failed(message: error.localizedDescription)
            return false
        }
    }

    func resetPhase() {
        phase = .idle
        progress = 0
    }

    // MARK: التجميع المرحلي (خارج الخيط الرئيسي)

    private nonisolated static func buildStagingDirectory(
        at stagingDirectory: URL,
        noteCount: Int,
        mediaCount: Int
    ) throws {

        let fm = FileManager.default
        try VaultStorage.ensureDirectory(at: stagingDirectory)

        for source in [VaultStorage.storeURL] + VaultStorage.storeSidecarURLs {
            guard fm.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let target = stagingDirectory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
            try fm.copyItem(at: source, to: target)
        }

        let mediaTarget = stagingDirectory.appending(path: VaultStorage.mediaDirectoryName, directoryHint: .isDirectory)
        try VaultStorage.ensureDirectory(at: mediaTarget)

        var hashes: [String: String] = [:]
        var totalBytes: Int64 = 0

        let contents = try fm.contentsOfDirectory(
            at: VaultStorage.mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for source in contents {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            let target = mediaTarget.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
            try fm.copyItem(at: source, to: target)

            hashes[source.lastPathComponent] = try EncryptionManager.sha256Hex(ofFileAt: source)
            totalBytes += Int64(values.fileSize ?? 0)
        }

        let manifest = BackupManifest(
            schemaVersion: BackupManifest.currentSchemaVersion,
            createdAt: Date(),
            appVersion: AppInfo.version,
            appBuild: AppInfo.build,
            deviceName: ProcessInfo.processInfo.hostName,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            noteCount: noteCount,
            mediaCount: mediaCount,
            mediaTotalBytes: totalBytes,
            mediaHashes: hashes
        )
        try BackupManifest.encoder().encode(manifest).write(
            to: stagingDirectory.appending(path: BackupManifest.fileName, directoryHint: .notDirectory),
            options: .atomic
        )
    }

    private nonisolated static func verifyExtractedPayload(at directory: URL) throws {

        let manifestURL = directory.appending(path: BackupManifest.fileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            throw BackupError.manifestMissing
        }

        let manifest = try BackupManifest.decoder().decode(
            BackupManifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        guard manifest.isCompatible else { throw BackupError.manifestIncompatible(manifest.schemaVersion) }

        let storeURL = directory.appending(path: VaultStorage.storeFileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)) else {
            throw BackupError.integrityCheckFailed(VaultStorage.storeFileName)
        }

        let mediaDirectory = directory.appending(path: VaultStorage.mediaDirectoryName, directoryHint: .isDirectory)

        for (fileName, expectedHash) in manifest.mediaHashes {
            // حماية من أسماء تحتوي مسارات (../).
            guard fileName == (fileName as NSString).lastPathComponent, !fileName.isEmpty else {
                throw BackupError.integrityCheckFailed(fileName)
            }
            let fileURL = mediaDirectory.appending(path: fileName, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
                throw BackupError.integrityCheckFailed(fileName)
            }
            guard try EncryptionManager.sha256Hex(ofFileAt: fileURL) == expectedHash else {
                throw BackupError.integrityCheckFailed(fileName)
            }
        }
    }

    // MARK: أدوات

    /// يربط تقارير التقدّم القادمة من خيوط خلفية بخاصية `progress` على الخيط الرئيسي.
    private func progressReporter() -> @Sendable (Double) -> Void {
        { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
    }

    private nonisolated static func makeBackupFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SecureVault-\(formatter.string(from: Date())).enc"
    }
}
