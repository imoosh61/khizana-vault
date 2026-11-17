//
//  MediaGalleryView.swift
//  SecureVault
//
//  شبكة الصور والفيديوهات: استيراد من ألبوم الصور، تصفية، تحديد وحذف، ومعاينة بملء الشاشة.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import CoreData

// MARK: - نموذج الاستيراد

@MainActor
final class MediaImportViewModel: ObservableObject {

    @Published private(set) var isImporting = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published var resultMessage: String?

    func importItems(_ items: [PhotosPickerItem], context: NSManagedObjectContext) async {
        guard !items.isEmpty, !isImporting else { return }

        isImporting = true
        completed = 0
        total = items.count

        var added = 0
        var duplicates = 0
        var failures = 0

        for item in items {
            do {
                let info = try await MediaFileStore.importPickerItem(item)

                if isDuplicate(hash: info.contentHash, in: context) {
                    MediaFileStore.removeFile(named: info.fileName)
                    duplicates += 1
                } else {
                    MediaItem.insert(in: context, info: info)
                    do {
                        try context.saveIfNeeded()
                        added += 1
                    } catch {
                        context.rollback()
                        MediaFileStore.removeFile(named: info.fileName)
                        failures += 1
                    }
                }
            } catch {
                failures += 1
            }
            completed += 1
        }

        isImporting = false

        var parts: [String] = []
        if added > 0 { parts.append(String(format: String(localized: "تمت إضافة %lld"), added)) }
        if duplicates > 0 { parts.append(String(format: String(localized: "تم تخطي %lld مكرر"), duplicates)) }
        if failures > 0 { parts.append(String(format: String(localized: "فشل استيراد %lld"), failures)) }
        resultMessage = parts.joined(separator: " • ")
    }

    /// استيراد صور/فيديوهات من تطبيق «الملفات».
    func importFileURLs(_ urls: [URL], context: NSManagedObjectContext) async {
        guard !urls.isEmpty, !isImporting else { return }

        isImporting = true
        completed = 0
        total = urls.count

        var added = 0
        var duplicates = 0
        var failures = 0

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            let kind: MediaKind?
            if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                kind = .video
            } else if type?.conforms(to: .image) == true {
                kind = .image
            } else {
                kind = nil
            }

            guard let kind else {
                failures += 1
                completed += 1
                continue
            }

            do {
                let info = try await MediaFileStore.importFile(from: url, kind: kind)
                if isDuplicate(hash: info.contentHash, in: context) {
                    MediaFileStore.removeFile(named: info.fileName)
                    duplicates += 1
                } else {
                    MediaItem.insert(in: context, info: info)
                    do {
                        try context.saveIfNeeded()
                        added += 1
                    } catch {
                        context.rollback()
                        MediaFileStore.removeFile(named: info.fileName)
                        failures += 1
                    }
                }
            } catch {
                failures += 1
            }
            completed += 1
        }

        isImporting = false

        var parts: [String] = []
        if added > 0 { parts.append(String(format: String(localized: "تمت إضافة %lld"), added)) }
        if duplicates > 0 { parts.append(String(format: String(localized: "تم تخطي %lld مكرر"), duplicates)) }
        if failures > 0 { parts.append(String(format: String(localized: "فشل استيراد %lld"), failures)) }
        resultMessage = parts.joined(separator: " • ")
    }

    private func isDuplicate(hash: String, in context: NSManagedObjectContext) -> Bool {
        let request = MediaItem.request()
        request.predicate = NSPredicate(format: "contentHash == %@", hash)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}

// MARK: - التصفية

enum MediaFilter: String, CaseIterable, Identifiable {
    case all, images, videos

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all:    return "الكل"
        case .images: return "الصور"
        case .videos: return "الفيديو"
        }
    }

    var predicate: NSPredicate? {
        switch self {
        case .all:    return nil
        case .images: return NSPredicate(format: "kindRaw == %@", MediaKind.image.rawValue)
        case .videos: return NSPredicate(format: "kindRaw == %@", MediaKind.video.rawValue)
        }
    }
}

// MARK: - الشاشة

struct MediaGalleryView: View {

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var importer: MediaImportViewModel
    @EnvironmentObject private var router: AppRouter

    @State private var filter: MediaFilter = .all
    @State private var isSelecting = false
    @State private var selection = Set<NSManagedObjectID>()
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("التصفية", selection: $filter) {
                ForEach(MediaFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if importer.isImporting {
                VStack(spacing: 6) {
                    ProgressView(value: Double(importer.completed), total: Double(max(importer.total, 1)))
                    Text("جارٍ الاستيراد \(importer.completed)/\(importer.total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            MediaGridContent(filter: filter, isSelecting: $isSelecting, selection: $selection)
        }
        .vaultBackground()
        .navigationTitle("الوسائط")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(isSelecting ? LocalizedStringKey("تم") : LocalizedStringKey("تحديد")) {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selection.isEmpty)
                } else {
                    Button {
                        router.showPhotoPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(importer.isImporting)
                    .accessibilityLabel(Text("استيراد من الصور"))
                }
            }
        }
        .confirmationDialog(
            "حذف \(selection.count) عنصر نهائياً من الخزنة؟",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("حذف", role: .destructive, action: deleteSelection)
            Button("إلغاء", role: .cancel) {}
        }
        .alert("تعذّرت العملية", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private func deleteSelection() {
        var fileNames: [String] = []

        for objectID in selection {
            guard let item = try? context.existingObject(with: objectID) as? MediaItem else { continue }
            fileNames.append(item.fileName)
            context.delete(item)
        }

        do {
            try context.saveIfNeeded()
            fileNames.forEach(MediaFileStore.removeFile(named:))
            selection.removeAll()
            isSelecting = false
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - الشبكة

private struct MediaGridContent: View {

    @FetchRequest private var items: FetchedResults<MediaItem>
    @Binding var isSelecting: Bool
    @Binding var selection: Set<NSManagedObjectID>

    @State private var viewer: ViewerSelection?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    struct ViewerSelection: Identifiable {
        let id = UUID()
        let index: Int
    }

    init(filter: MediaFilter, isSelecting: Binding<Bool>, selection: Binding<Set<NSManagedObjectID>>) {
        let request = MediaItem.request()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.predicate = filter.predicate
        _items = FetchRequest(fetchRequest: request, animation: .default)
        _isSelecting = isSelecting
        _selection = selection
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.objectID) { index, item in
                    MediaThumbnailCell(
                        item: item,
                        isSelecting: isSelecting,
                        isSelected: selection.contains(item.objectID)
                    )
                    .onTapGesture {
                        if isSelecting {
                            toggle(item.objectID)
                        } else {
                            viewer = ViewerSelection(index: index)
                        }
                    }
                    .contextMenu {
                        Button {
                            isSelecting = true
                            selection.insert(item.objectID)
                        } label: {
                            Label("تحديد", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                EmptyStateView(
                    systemImage: "photo.on.rectangle.angled",
                    title: "لا توجد وسائط",
                    message: "اضغط على + لاستيراد صور وفيديوهات من ألبوم الصور."
                )
            }
        }
        .fullScreenCover(item: $viewer) { selected in
            MediaViewerView(items: Array(items), startIndex: selected.index)
        }
    }

    private func toggle(_ id: NSManagedObjectID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

// MARK: - خلية المصغّرة

private struct MediaThumbnailCell: View {

    let item: MediaItem
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if item.managedObjectContext == nil || item.isDeleted {
                    Color.clear
                } else if let image = ThumbnailCache.shared.image(for: item) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.kind == .video ? "video" : "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.managedObjectContext != nil, !item.isDeleted, item.kind == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        if let duration = item.formattedDuration { Text(duration) }
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.managedObjectContext != nil, !item.isDeleted, item.isFavorite, !isSelecting {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .background(Circle().fill(.black.opacity(isSelected ? 0 : 0.25)))
                        .padding(6)
                }
            }
            .overlay {
                if isSelected { Color.accentColor.opacity(0.25) }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
