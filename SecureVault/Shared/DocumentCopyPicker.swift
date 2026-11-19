//
//  DocumentCopyPicker.swift
//  SecureVault
//
//  منتقي ملفات يعتمد على UIDocumentPickerViewController بوضع النسخ (asCopy):
//  يسلّم النظام نسخة جاهزة داخل مجلد التطبيق المؤقت، فلا نحتاج صلاحيات وصول
//  داخل مكان الملف الأصلي (iCloud وغيره). هذا أوثق من fileImporter في SwiftUI.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentCopyPicker: UIViewControllerRepresentable {

    let types: [UTType]
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
