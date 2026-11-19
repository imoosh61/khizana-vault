//
//  EncryptionManager.swift
//  SecureVault
//
//  تشفير AES-GCM-256 متدفّق بأجزاء، مع اشتقاق مفتاح PBKDF2-HMAC-SHA256 ثم HKDF.
//
//  صيغة ملف .enc:
//    [ الترويسة ] ثم تكرار: [ طول الجزء UInt32-BE ][ SealedBox.combined ]
//
//  الترويسة (Big-Endian):
//    magic 4 "SVLT" | version 1 | kdfID 1 | reserved 2 | iterations 4
//    saltLength 2 | salt N | chunkSize 4 | totalChunks 8 | plaintextSize 8
//
//  AAD لكل جزء = (بايتات الترويسة) + (رقم الجزء UInt64-BE) فيمنع إعادة الترتيب
//  وخلط الأجزاء بين ملفات والبتر.
//

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - الأخطاء

enum EncryptionError: LocalizedError, Equatable {
    case emptyPassword
    case keyDerivationFailed(Int32)
    case invalidHeader
    case unsupportedVersion(UInt8)
    case unsupportedKDF(UInt8)
    case corruptedData
    case truncatedFile
    case authenticationFailed
    case ioFailure(String)
    case sourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String(localized: "كلمة مرور التشفير لا يمكن أن تكون فارغة.")
        case .keyDerivationFailed(let status):
            return String(localized: "فشل اشتقاق مفتاح التشفير (رمز \(Int(status))).")
        case .invalidHeader:
            return String(localized: "الملف ليس نسخة احتياطية صالحة لهذا التطبيق.")
        case .unsupportedVersion(let version):
            return String(localized: "إصدار النسخة الاحتياطية (\(Int(version))) غير مدعوم في هذه النسخة من التطبيق.")
        case .unsupportedKDF(let id):
            return String(localized: "طريقة اشتقاق المفتاح (\(Int(id))) غير مدعومة.")
        case .corruptedData:
            return String(localized: "بيانات النسخة الاحتياطية تالفة.")
        case .truncatedFile:
            return String(localized: "ملف النسخة الاحتياطية ناقص أو مبتور.")
        case .authenticationFailed:
            return String(localized: "كلمة المرور غير صحيحة أو تم العبث بالملف.")
        case .ioFailure(let message):
            return String(localized: "خطأ في قراءة/كتابة الملف: \(message)")
        case .sourceNotFound(let path):
            return String(localized: "الملف المصدر غير موجود: \(path)")
        }
    }
}

// MARK: - الترويسة

struct EncryptionHeader: Equatable, Sendable {

    static let magic: [UInt8] = [0x53, 0x56, 0x4C, 0x54]   // "SVLT"
    static let currentVersion: UInt8 = 1
    static let kdfPBKDF2SHA256: UInt8 = 1
    /// حدود منطقية لمنع ملف خبيث من فرض تكلفة اشتقاق هائلة.
    static let iterationRange: ClosedRange<UInt32> = 100_000...5_000_000

    var version: UInt8
    var kdfID: UInt8
    var iterations: UInt32
    var salt: Data
    var chunkSize: UInt32
    var totalChunks: UInt64
    var plaintextSize: UInt64

    func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: EncryptionHeader.magic)
        data.append(version)
        data.append(kdfID)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(iterations)
        data.appendBigEndian(UInt16(salt.count))
        data.append(salt)
        data.appendBigEndian(chunkSize)
        data.appendBigEndian(totalChunks)
        data.appendBigEndian(plaintextSize)
        return data
    }

    static func decode(from data: Data) throws -> (header: EncryptionHeader, consumed: Int) {
        var reader = ByteReader(data)

        guard try reader.readBytes(4) == magic else { throw EncryptionError.invalidHeader }

        let version = try reader.readUInt8()
        guard version == currentVersion else { throw EncryptionError.unsupportedVersion(version) }

        let kdfID = try reader.readUInt8()
        guard kdfID == kdfPBKDF2SHA256 else { throw EncryptionError.unsupportedKDF(kdfID) }

        _ = try reader.readUInt16()
        let iterations = try reader.readUInt32()
        guard iterationRange.contains(iterations) else { throw EncryptionError.invalidHeader }

        let saltLength = Int(try reader.readUInt16())
        guard saltLength > 0, saltLength <= 64 else { throw EncryptionError.invalidHeader }
        let salt = Data(try reader.readBytes(saltLength))

        let chunkSize = try reader.readUInt32()
        guard chunkSize > 0, chunkSize <= 64 * 1024 * 1024 else { throw EncryptionError.invalidHeader }

        let totalChunks = try reader.readUInt64()
        let plaintextSize = try reader.readUInt64()

        let header = EncryptionHeader(
            version: version,
            kdfID: kdfID,
            iterations: iterations,
            salt: salt,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            plaintextSize: plaintextSize
        )
        return (header, reader.offset)
    }
}

// MARK: - المدير

struct EncryptionManager: Sendable {

    /// يتوافق مع توصيات OWASP لـ PBKDF2-HMAC-SHA256.
    static let defaultIterations: UInt32 = 310_000
    static let saltLength = 16
    static let defaultChunkSize: UInt32 = 4 * 1024 * 1024
    static let derivedKeyLength = 32

    private static let fileKeyInfo = Data("SecureVault.FileKey.v1".utf8)
    private static let verifierInfo = Data("SecureVault.PasscodeVerifier.v1".utf8)

    // MARK: اشتقاق المفاتيح

    static func randomSalt(length: Int = saltLength) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            return SymmetricKey(size: SymmetricKeySize(bitCount: length * 8)).withUnsafeBytes { Data($0) }
        }
        return Data(bytes)
    }

    static func pbkdf2(password: String, salt: Data, iterations: UInt32, keyLength: Int = derivedKeyLength) throws -> Data {
        guard !password.isEmpty else { throw EncryptionError.emptyPassword }

        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: keyLength)

        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            saltBytes.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(passwordBuffer.baseAddress)?.assumingMemoryBound(to: Int8.self),
                    passwordBytes.count,
                    saltBuffer.baseAddress,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    keyLength
                )
            }
        }

        guard status == kCCSuccess else { throw EncryptionError.keyDerivationFailed(status) }
        return Data(derived)
    }

    /// مفتاح تشفير الملفات: PBKDF2 ثم HKDF لفصل الاستخدامات.
    static func deriveFileKey(password: String, salt: Data, iterations: UInt32 = defaultIterations) throws -> SymmetricKey {
        let master = try pbkdf2(password: password, salt: salt, iterations: iterations)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master),
            salt: salt,
            info: fileKeyInfo,
            outputByteCount: derivedKeyLength
        )
    }

    /// مُتحقق رمز مرور القفل — `info` مختلف فلا يصلح لفك تشفير النسخ الاحتياطية.
    static func derivePasscodeVerifier(passcode: String, salt: Data, iterations: UInt32 = defaultIterations) throws -> Data {
        let master = try pbkdf2(password: passcode, salt: salt, iterations: iterations)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master),
            salt: salt,
            info: verifierInfo,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: تشفير الملفات (متدفّق)

    static func encryptFile(
        at source: URL,
        to destination: URL,
        password: String,
        iterations: UInt32 = defaultIterations,
        chunkSize: UInt32 = defaultChunkSize,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {

        guard !password.isEmpty else { throw EncryptionError.emptyPassword }

        let fm = FileManager.default
        let sourcePath = source.path(percentEncoded: false)
        guard fm.fileExists(atPath: sourcePath) else { throw EncryptionError.sourceNotFound(sourcePath) }

        let attributes = try fm.attributesOfItem(atPath: sourcePath)
        let plaintextSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        let salt = randomSalt()
        let key = try deriveFileKey(password: password, salt: salt, iterations: iterations)

        let totalChunks: UInt64 = plaintextSize == 0
            ? 0
            : (plaintextSize + UInt64(chunkSize) - 1) / UInt64(chunkSize)

        let header = EncryptionHeader(
            version: EncryptionHeader.currentVersion,
            kdfID: EncryptionHeader.kdfPBKDF2SHA256,
            iterations: iterations,
            salt: salt,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            plaintextSize: plaintextSize
        )
        let headerData = header.encoded()

        let destinationPath = destination.path(percentEncoded: false)
        if fm.fileExists(atPath: destinationPath) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destinationPath, contents: nil) else {
            throw EncryptionError.ioFailure("تعذّر إنشاء ملف الوجهة.")
        }

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        do {
            try output.write(contentsOf: headerData)

            var index: UInt64 = 0
            var processed: UInt64 = 0

            while index < totalChunks {
                guard let plainChunk = try input.read(upToCount: Int(chunkSize)), !plainChunk.isEmpty else {
                    throw EncryptionError.truncatedFile
                }

                let aad = headerData + index.bigEndianData
                let sealed = try AES.GCM.seal(plainChunk, using: key, authenticating: aad)
                guard let combined = sealed.combined else { throw EncryptionError.corruptedData }

                var framed = Data()
                framed.appendBigEndian(UInt32(combined.count))
                framed.append(combined)
                try output.write(contentsOf: framed)

                processed += UInt64(plainChunk.count)
                index += 1

                if let progress, plaintextSize > 0 {
                    progress(min(1.0, Double(processed) / Double(plaintextSize)))
                }
            }

            try output.synchronize()
            progress?(1.0)
        } catch let error as EncryptionError {
            try? fm.removeItem(at: destination)
            throw error
        } catch {
            try? fm.removeItem(at: destination)
            throw EncryptionError.ioFailure(error.localizedDescription)
        }
    }

    static func decryptFile(
        at source: URL,
        to destination: URL,
        password: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {

        guard !password.isEmpty else { throw EncryptionError.emptyPassword }

        let fm = FileManager.default
        let sourcePath = source.path(percentEncoded: false)
        guard fm.fileExists(atPath: sourcePath) else { throw EncryptionError.sourceNotFound(sourcePath) }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        // أكبر ترويسة ممكنة: 4+1+1+2+4+2+64+4+8+8
        let maxHeaderSize = 98
        guard let headerProbe = try input.read(upToCount: maxHeaderSize), !headerProbe.isEmpty else {
            throw EncryptionError.invalidHeader
        }

        let (header, consumed) = try EncryptionHeader.decode(from: headerProbe)
        let headerData = Data(headerProbe.prefix(consumed))
        try input.seek(toOffset: UInt64(consumed))

        let key = try deriveFileKey(password: password, salt: header.salt, iterations: header.iterations)

        let destinationPath = destination.path(percentEncoded: false)
        if fm.fileExists(atPath: destinationPath) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destinationPath, contents: nil) else {
            throw EncryptionError.ioFailure("تعذّر إنشاء ملف الوجهة.")
        }

        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        do {
            var index: UInt64 = 0
            var written: UInt64 = 0

            while index < header.totalChunks {
                guard let lengthData = try input.read(upToCount: 4), lengthData.count == 4 else {
                    throw EncryptionError.truncatedFile
                }
                let frameLength = Int(UInt32(bigEndianData: lengthData))
                guard frameLength > 0, frameLength <= Int(header.chunkSize) + 64 else {
                    throw EncryptionError.corruptedData
                }

                guard let frame = try input.read(upToCount: frameLength), frame.count == frameLength else {
                    throw EncryptionError.truncatedFile
                }

                let aad = headerData + index.bigEndianData

                let plainChunk: Data
                do {
                    let box = try AES.GCM.SealedBox(combined: frame)
                    plainChunk = try AES.GCM.open(box, using: key, authenticating: aad)
                } catch {
                    throw EncryptionError.authenticationFailed
                }

                try output.write(contentsOf: plainChunk)
                written += UInt64(plainChunk.count)
                index += 1

                if let progress, header.plaintextSize > 0 {
                    progress(min(1.0, Double(written) / Double(header.plaintextSize)))
                }
            }

            guard written == header.plaintextSize else { throw EncryptionError.truncatedFile }

            try output.synchronize()
            progress?(1.0)
        } catch let error as EncryptionError {
            try? fm.removeItem(at: destination)
            throw error
        } catch {
            try? fm.removeItem(at: destination)
            throw EncryptionError.ioFailure(error.localizedDescription)
        }
    }

    // MARK: تجزئة الملفات

    static func sha256Hex(ofFileAt url: URL, bufferSize: Int = 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var finished = false
        while !finished {
            // autoreleasepool: بدونه تتراكم أجزاء الـ 1MB في الذاكرة حتى نهاية الملف (انهيار مع الفيديوهات الكبيرة).
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: bufferSize), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    finished = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - أدوات البايتات

private struct ByteReader {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= data.count else { throw EncryptionError.truncatedFile }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return [UInt8](data[start..<end])
    }

    mutating func readUInt8() throws -> UInt8 { try readBytes(1)[0] }

    mutating func readUInt16() throws -> UInt16 {
        try readBytes(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        try readBytes(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension FixedWidthInteger {
    var bigEndianData: Data {
        Swift.withUnsafeBytes(of: bigEndian) { Data($0) }
    }

    /// يقرأ عدداً من بايتات Big-Endian (حتى 8 بايتات).
    init(bigEndianData data: Data) {
        var value: UInt64 = 0
        for byte in data.prefix(MemoryLayout<Self>.size) {
            value = (value << 8) | UInt64(byte)
        }
        self = Self(truncatingIfNeeded: value)
    }
}
