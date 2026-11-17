//
//  MediaFileStore.swift
//  SecureVault
//
//  استيراد الصور والفيديوهات إلى مجلد الخزنة، توليد المصغّرات، وتحميل الصور للعرض.
//

import Foundation
import UIKit
import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - نتيجة الاستيراد

struct ImportedMediaInfo: Sendable {
    var fileName: String
    var originalFileName: String
    var kind: MediaKind
    var byteCount: Int64
    var createdAt: Date
    var durationSeconds: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var thumbnailData: Data?
    var contentHash: String
}

enum MediaImportError: LocalizedError {
    case unreadable
    case copyFailed(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable:        return String(localized: "تعذّر قراءة الملف المحدد.")
        case .copyFailed(let m): return String(localized: "فشل نسخ الملف إلى الخزنة: \(m)")
        case .unsupported:       return String(localized: "نوع الملف غير مدعوم.")
        }
    }
}

// MARK: - ملفات PhotosPicker (نسخ إلى مجلد مؤقت دون تحميلها في الذاكرة)

private func receiveToScratch(_ received: URL) throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let target = scratch.appending(path: received.lastPathComponent, directoryHint: .notDirectory)
    try FileManager.default.copyItem(at: received, to: target)
    return target
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try receiveToScratch(received.file))
        }
    }
}

struct PickedImage: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedImage(url: try receiveToScratch(received.file))
        }
    }
}

// MARK: - المتجر

enum MediaFileStore {

    private static let thumbnailMaxPixel: CGFloat = 480

    /// يستورد عنصراً مختاراً من PhotosPicker.
    static func importPickerItem(_ item: PhotosPickerItem) async throws -> ImportedMediaInfo {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

        let tempURL: URL
        if isVideo {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw MediaImportError.unreadable
            }
            tempURL = movie.url
        } else {
            guard let image = try await item.loadTransferable(type: PickedImage.self) else {
                throw MediaImportError.unreadable
            }
            tempURL = image.url
        }

        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        return try await importFile(from: tempURL, kind: isVideo ? .video : .image)
    }

    /// ينسخ الملف إلى الخزنة ويحسب التجزئة والبيانات الوصفية والمصغّرة.
    static func importFile(from source: URL, kind: MediaKind) async throws -> ImportedMediaInfo {

        let originalName = source.lastPathComponent
        var ext = source.pathExtension.lowercased()
        if ext.isEmpty { ext = (kind == .video) ? "mov" : "jpg" }

        let storedName = "\(UUID().uuidString.lowercased()).\(ext)"
        let target = VaultStorage.mediaDirectory.appending(path: storedName, directoryHint: .notDirectory)

        VaultStorage.prepareDirectories()

        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            throw MediaImportError.copyFailed(error.localizedDescription)
        }
        VaultStorage.protectFile(at: target)

        do {
            let byteCount = (try FileManager.default.attributesOfItem(atPath: target.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value ?? 0
            let hash = try EncryptionManager.sha256Hex(ofFileAt: target)

            switch kind {
            case .image:
                let meta = imageMetadata(at: target)
                return ImportedMediaInfo(
                    fileName: storedName,
                    originalFileName: originalName,
                    kind: .image,
                    byteCount: byteCount,
                    createdAt: meta.createdAt ?? Date(),
                    durationSeconds: 0,
                    pixelWidth: meta.width,
                    pixelHeight: meta.height,
                    thumbnailData: imageThumbnail(at: target),
                    contentHash: hash
                )
            case .video:
                let meta = await videoMetadata(at: target)
                return ImportedMediaInfo(
                    fileName: storedName,
                    originalFileName: originalName,
                    kind: .video,
                    byteCount: byteCount,
                    createdAt: meta.createdAt ?? Date(),
                    durationSeconds: meta.duration,
                    pixelWidth: meta.width,
                    pixelHeight: meta.height,
                    thumbnailData: await videoThumbnail(at: target, duration: meta.duration),
                    contentHash: hash
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// يحذف ملف الوسائط من القرص.
    static func removeFile(named fileName: String) {
        let url = VaultStorage.mediaDirectory.appending(path: fileName, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: الصور

    private static func imageMetadata(at url: URL) -> (width: Int, height: Int, createdAt: Date?) {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0, nil) }

        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        // تبديل الأبعاد عند الدوران الجانبي (EXIF 5...8).
        if let orientation = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }

        var created: Date?
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            created = formatter.date(from: raw)
        }
        return (width, height, created)
    }

    private static func imageThumbnail(at url: URL) -> Data? {
        guard let image = downsample(url: url, maxPixel: thumbnailMaxPixel) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    /// تصغير فعّال للذاكرة عبر ImageIO دون فك الصورة كاملة.
    static func downsample(url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// يحمّل صورة للعرض بالحجم الكامل تقريباً (محدودة بـ `maxPixel`) خارج الخيط الرئيسي.
    static func loadDisplayImage(at url: URL, maxPixel: CGFloat = 3000) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            downsample(url: url, maxPixel: maxPixel).map { UIImage(cgImage: $0) }
        }.value
    }

    // MARK: الفيديو

    private static func videoMetadata(at url: URL) async -> (duration: Double, width: Int, height: Int, createdAt: Date?) {
        let asset = AVURLAsset(url: url)
        var duration = 0.0
        var width = 0
        var height = 0

        if let time = try? await asset.load(.duration), time.isNumeric {
            duration = max(0, time.seconds)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let applied = size.applying(transform)
            width = Int(abs(applied.width))
            height = Int(abs(applied.height))
        }

        var created: Date?
        if let creation = try? await asset.load(.creationDate) {
            created = try? await creation.load(.dateValue)
        }
        return (duration, width, height, created)
    }

    private static func videoThumbnail(at url: URL, duration: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixel, height: thumbnailMaxPixel)

        let seconds = duration > 2 ? 1.0 : 0.0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)

        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8)
    }
}

// MARK: - ذاكرة مؤقتة للمصغّرات

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 600
    }

    @MainActor
    func image(for item: MediaItem) -> UIImage? {
        guard item.managedObjectContext != nil, !item.isDeleted else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = item.thumbnailData, let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func removeAll() { cache.removeAllObjects() }
}
