//
//  Models.swift
//  SecureVault
//
//  نماذج البيانات (Core Data مبني برمجياً) + تخطيط التخزين + بيان النسخة الاحتياطية.
//  ملاحظة: SwiftData تتطلب iOS 17، لذلك نستخدم Core Data لدعم iOS 16.
//

import Foundation
import CoreData

// MARK: - تخطيط التخزين على القرص

enum VaultStorage {

    static let rootDirectoryName = "SecureVault"
    static let mediaDirectoryName = "Media"
    static let storeFileName = "Vault.store"
    static let pendingRestoreDirectoryName = "PendingRestore"

    static var rootDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: rootDirectoryName, directoryHint: .isDirectory)
    }

    static var mediaDirectory: URL {
        rootDirectory.appending(path: mediaDirectoryName, directoryHint: .isDirectory)
    }

    static var storeURL: URL {
        rootDirectory.appending(path: storeFileName, directoryHint: .notDirectory)
    }

    /// ملفات SQLite المصاحبة (نستخدم journal_mode=DELETE لكن نبقيها للاحتياط).
    static var storeSidecarURLs: [URL] {
        ["-wal", "-shm"].map {
            rootDirectory.appending(path: "\(storeFileName)\($0)", directoryHint: .notDirectory)
        }
    }

    static var pendingRestoreDirectory: URL {
        rootDirectory.appending(path: pendingRestoreDirectoryName, directoryHint: .isDirectory)
    }

    /// ينشئ المجلدات الأساسية. يُستدعى عند الإقلاع وبعد الاستعادة.
    static func prepareDirectories() {
        try? ensureDirectory(at: rootDirectory)
        try? ensureDirectory(at: mediaDirectory)
    }

    /// مجلد عمل مؤقت (أرشفة/تشفير) — محمي ويُحذف بعد انتهاء العملية.
    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try ensureDirectory(at: url)
        return url
    }

    /// ينشئ المجلد إن لم يكن موجوداً ويطبّق الحماية الكاملة ويستثنيه من نسخ iCloud/iTunes.
    static func ensureDirectory(at url: URL, protected: Bool = true) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard protected else { return }
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    static func protectFile(at url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }
}

// MARK: - أنواع الوسائط

enum MediaKind: String, CaseIterable, Sendable {
    case image
    case video

    var displayName: String {
        switch self {
        case .image: return String(localized: "صورة")
        case .video: return String(localized: "فيديو")
        }
    }
}

// MARK: - كيانات Core Data

private enum EntityName {
    static let note = "Note"
    static let media = "MediaItem"
    static let backup = "BackupRecord"
}

@objc(Note)
final class Note: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var body: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var isPinned: Bool
    @NSManaged var isFavorite: Bool
    /// وسوم مخزّنة كنص ",a,b," لتسهيل البحث.
    @NSManaged var tagsRaw: String
    @NSManaged var attachments: Set<MediaItem>

    static func request() -> NSFetchRequest<Note> {
        NSFetchRequest<Note>(entityName: EntityName.note)
    }

    @discardableResult
    static func insert(
        in context: NSManagedObjectContext,
        title: String = "",
        body: String = "",
        tags: [String] = [],
        isPinned: Bool = false
    ) -> Note {
        let note = NSEntityDescription.insertNewObject(forEntityName: EntityName.note, into: context) as! Note
        let now = Date()
        note.id = UUID()
        note.title = title
        note.body = body
        note.createdAt = now
        note.updatedAt = now
        note.isPinned = isPinned
        note.isFavorite = false
        note.tags = tags
        return note
    }

    var tags: [String] {
        get {
            tagsRaw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            tagsRaw = cleaned.isEmpty ? "" : "," + cleaned.joined(separator: ",") + ","
        }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let firstLine, !firstLine.isEmpty { return firstLine }
        return String(localized: "ملاحظة بدون عنوان")
    }

    /// نص مختصر للمعاينة دون رموز Markdown.
    var previewText: String {
        let cleaned = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var text = String(line).trimmingCharacters(in: .whitespaces)
                for prefix in ["- [ ] ", "- [x] ", "- [X] ", "### ", "## ", "# ", "- ", "* ", "> "] where text.hasPrefix(prefix) {
                    text.removeFirst(prefix.count)
                    break
                }
                return text
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
            .joined(separator: " · ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@objc(MediaItem)
final class MediaItem: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    /// اسم الملف النسبي داخل مجلد الوسائط — لا نخزّن مساراً مطلقاً لأن مسار الحاوية يتغيّر.
    @NSManaged var fileName: String
    @NSManaged var originalFileName: String
    @NSManaged var kindRaw: String
    @NSManaged var byteCount: Int64
    @NSManaged var createdAt: Date
    @NSManaged var importedAt: Date
    /// مدة الفيديو بالثواني (0 للصور).
    @NSManaged var durationSeconds: Double
    @NSManaged var pixelWidth: Int32
    @NSManaged var pixelHeight: Int32
    @NSManaged var thumbnailData: Data?
    /// SHA-256 للملف الأصلي (كشف التكرار + التحقق).
    @NSManaged var contentHash: String
    @NSManaged var isFavorite: Bool
    @NSManaged var note: Note?

    static func request() -> NSFetchRequest<MediaItem> {
        NSFetchRequest<MediaItem>(entityName: EntityName.media)
    }

    @discardableResult
    static func insert(in context: NSManagedObjectContext, info: ImportedMediaInfo) -> MediaItem {
        let item = NSEntityDescription.insertNewObject(forEntityName: EntityName.media, into: context) as! MediaItem
        item.id = UUID()
        item.fileName = info.fileName
        item.originalFileName = info.originalFileName
        item.kindRaw = info.kind.rawValue
        item.byteCount = info.byteCount
        item.createdAt = info.createdAt
        item.importedAt = Date()
        item.durationSeconds = info.durationSeconds
        item.pixelWidth = Int32(clamping: info.pixelWidth)
        item.pixelHeight = Int32(clamping: info.pixelHeight)
        item.thumbnailData = info.thumbnailData
        item.contentHash = info.contentHash
        item.isFavorite = false
        return item
    }

    var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .image }
        set { kindRaw = newValue.rawValue }
    }

    var fileURL: URL {
        VaultStorage.mediaDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var formattedDuration: String? {
        guard durationSeconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = durationSeconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter.string(from: durationSeconds)
    }
}

@objc(BackupRecord)
final class BackupRecord: NSManagedObject, Identifiable {

    @NSManaged var id: UUID
    @NSManaged var remoteFileID: String
    @NSManaged var fileName: String
    @NSManaged var createdAt: Date
    @NSManaged var encryptedByteCount: Int64
    @NSManaged var noteCount: Int32
    @NSManaged var mediaCount: Int32
    @NSManaged var deviceName: String
    @NSManaged var appVersion: String

    static func request() -> NSFetchRequest<BackupRecord> {
        NSFetchRequest<BackupRecord>(entityName: EntityName.backup)
    }

    @discardableResult
    static func insert(
        in context: NSManagedObjectContext,
        remoteFileID: String,
        fileName: String,
        createdAt: Date,
        encryptedByteCount: Int64,
        noteCount: Int,
        mediaCount: Int,
        deviceName: String,
        appVersion: String
    ) -> BackupRecord {
        let record = NSEntityDescription.insertNewObject(forEntityName: EntityName.backup, into: context) as! BackupRecord
        record.id = UUID()
        record.remoteFileID = remoteFileID
        record.fileName = fileName
        record.createdAt = createdAt
        record.encryptedByteCount = encryptedByteCount
        record.noteCount = Int32(clamping: noteCount)
        record.mediaCount = Int32(clamping: mediaCount)
        record.deviceName = deviceName
        record.appVersion = appVersion
        return record
    }
}

// MARK: - نموذج Core Data البرمجي

enum VaultModel {

    /// نسخة واحدة فقط من النموذج لتجنّب تعارض تعريف الكيانات.
    static let shared: NSManagedObjectModel = build()

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil,
        externalStorage: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        if externalStorage { attribute.allowsExternalBinaryDataStorage = true }
        return attribute
    }

    private static func build() -> NSManagedObjectModel {

        // Note
        let note = NSEntityDescription()
        note.name = EntityName.note
        note.managedObjectClassName = "Note"

        // MediaItem
        let media = NSEntityDescription()
        media.name = EntityName.media
        media.managedObjectClassName = "MediaItem"

        // BackupRecord
        let backup = NSEntityDescription()
        backup.name = EntityName.backup
        backup.managedObjectClassName = "BackupRecord"

        // العلاقات
        let attachments = NSRelationshipDescription()
        attachments.name = "attachments"
        attachments.destinationEntity = media
        attachments.minCount = 0
        attachments.maxCount = 0                    // to-many
        attachments.isOptional = true
        attachments.deleteRule = .cascadeDeleteRule

        let noteRelation = NSRelationshipDescription()
        noteRelation.name = "note"
        noteRelation.destinationEntity = note
        noteRelation.minCount = 0
        noteRelation.maxCount = 1
        noteRelation.isOptional = true
        noteRelation.deleteRule = .nullifyDeleteRule

        attachments.inverseRelationship = noteRelation
        noteRelation.inverseRelationship = attachments

        note.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("title", .stringAttributeType, defaultValue: ""),
            attribute("body", .stringAttributeType, defaultValue: ""),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("isPinned", .booleanAttributeType, defaultValue: false),
            attribute("isFavorite", .booleanAttributeType, defaultValue: false),
            attribute("tagsRaw", .stringAttributeType, defaultValue: ""),
            attachments
        ]

        media.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("fileName", .stringAttributeType, defaultValue: ""),
            attribute("originalFileName", .stringAttributeType, defaultValue: ""),
            attribute("kindRaw", .stringAttributeType, defaultValue: MediaKind.image.rawValue),
            attribute("byteCount", .integer64AttributeType, defaultValue: 0),
            attribute("createdAt", .dateAttributeType),
            attribute("importedAt", .dateAttributeType),
            attribute("durationSeconds", .doubleAttributeType, defaultValue: 0.0),
            attribute("pixelWidth", .integer32AttributeType, defaultValue: 0),
            attribute("pixelHeight", .integer32AttributeType, defaultValue: 0),
            attribute("thumbnailData", .binaryDataAttributeType, optional: true, externalStorage: true),
            attribute("contentHash", .stringAttributeType, defaultValue: ""),
            attribute("isFavorite", .booleanAttributeType, defaultValue: false),
            noteRelation
        ]

        backup.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("remoteFileID", .stringAttributeType, defaultValue: ""),
            attribute("fileName", .stringAttributeType, defaultValue: ""),
            attribute("createdAt", .dateAttributeType),
            attribute("encryptedByteCount", .integer64AttributeType, defaultValue: 0),
            attribute("noteCount", .integer32AttributeType, defaultValue: 0),
            attribute("mediaCount", .integer32AttributeType, defaultValue: 0),
            attribute("deviceName", .stringAttributeType, defaultValue: ""),
            attribute("appVersion", .stringAttributeType, defaultValue: "")
        ]

        let model = NSManagedObjectModel()
        model.entities = [note, media, backup]
        return model
    }
}

// MARK: - حاوية Core Data

final class PersistenceController {

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    /// - Important: يجب استدعاء `VaultRestore.applyPendingRestoreIfNeeded()` قبل إنشاء هذا الكائن.
    init(inMemory: Bool = false) throws {
        VaultStorage.prepareDirectories()

        let container = NSPersistentContainer(name: "SecureVault", managedObjectModel: VaultModel.shared)

        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        } else {
            description = NSPersistentStoreDescription(url: VaultStorage.storeURL)
            description.type = NSSQLiteStoreType
            description.setOption(
                FileProtectionType.complete as NSObject,
                forKey: NSPersistentStoreFileProtectionKey
            )
            // بدون WAL: ملف قاعدة واحد متّسق بعد كل حفظ، فيسهل نسخه احتياطياً.
            description.setOption(
                ["journal_mode": "DELETE"] as NSDictionary,
                forKey: NSSQLitePragmasOption
            )
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error { loadError = error }
        }
        if let loadError { throw loadError }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.undoManager = nil

        self.container = container
    }

    /// يفصل المخزن عن المنسّق (مطلوب قبل استبدال ملف القاعدة أثناء الاستعادة).
    func tearDown() {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }
}

extension NSManagedObjectContext {
    /// يحفظ فقط عند وجود تغييرات.
    func saveIfNeeded() throws {
        if hasChanges { try save() }
    }
}

// MARK: - بيان النسخة الاحتياطية (داخل الأرشيف)

struct BackupManifest: Codable, Sendable, Equatable {

    static let currentSchemaVersion = 1
    static let fileName = "manifest.json"

    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var deviceName: String
    var systemVersion: String
    var noteCount: Int
    var mediaCount: Int
    var mediaTotalBytes: Int64
    /// اسم الملف → SHA-256، للتحقق من سلامة الوسائط بعد الاستعادة.
    var mediaHashes: [String: String]

    var isCompatible: Bool { schemaVersion <= BackupManifest.currentSchemaVersion }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - معلومات التطبيق

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
