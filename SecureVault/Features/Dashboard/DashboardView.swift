//
//  DashboardView.swift
//  SecureVault
//
//  الشاشة الرئيسية: الحالة الأمنية وآخر نسخة سحابية، إحصائيات، بحث ذكي، ووصول سريع.
//

import SwiftUI
import CoreData

struct DashboardView: View {

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var auth: BiometricAuthManager
    @EnvironmentObject private var backup: CloudBackupManager

    @FetchRequest private var notes: FetchedResults<Note>
    @FetchRequest private var media: FetchedResults<MediaItem>
    @FetchRequest private var lastBackups: FetchedResults<BackupRecord>

    @State private var searchText = ""

    init() {
        let noteRequest = Note.request()
        noteRequest.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        _notes = FetchRequest(fetchRequest: noteRequest, animation: .default)

        let mediaRequest = MediaItem.request()
        mediaRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        _media = FetchRequest(fetchRequest: mediaRequest, animation: .default)

        let backupRequest = BackupRecord.request()
        backupRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        backupRequest.fetchLimit = 1
        _lastBackups = FetchRequest(fetchRequest: backupRequest, animation: .default)
    }

    private var query: String { searchText.trimmed }

    private var totalMediaBytes: Int64 {
        media.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        ScrollView {
            if query.isEmpty {
                overview
            } else {
                searchResults
            }
        }
        .vaultBackground()
        .navigationTitle("الرئيسية")
        .searchable(text: $searchText, prompt: Text("بحث في الملاحظات والوسائط"))
    }

    // MARK: النظرة العامة

    private var overview: some View {
        VStack(spacing: 20) {
            securityCard
            statsRow
            quickAccess
            recentMedia
        }
        .padding(16)
        .padding(.bottom, 90)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    // MARK: بطاقة الأمان

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.secure)
                    .frame(width: 52, height: 52)
                    .background(Theme.secure.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("الخزنة محمية")
                        .font(.title3.bold())
                    SecureBadge(title: "AES-GCM-256", systemImage: "lock.fill")
                }
                Spacer(minLength: 0)
            }

            Divider()

            infoRow(
                icon: auth.canUseBiometrics ? auth.biometryKind.systemImageName : "number.circle",
                title: "القفل",
                value: auth.canUseBiometrics
                    ? Text(verbatim: auth.biometryKind.displayName) + Text(verbatim: " + ") + Text("رمز التطبيق")
                    : Text("رمز التطبيق")
            )

            if let last = lastBackups.first, last.managedObjectContext != nil {
                infoRow(
                    icon: "icloud.and.arrow.up.fill",
                    title: "آخر نسخة سحابية",
                    value: Text(last.createdAt, style: .relative) + Text(verbatim: " • ") + Text(verbatim: last.formattedSize),
                    tint: Theme.secure
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("لم تُنشأ نسخة سحابية بعد")
                            .font(.subheadline.weight(.semibold))
                        Text("أنشئ نسخة مشفّرة لحماية بياناتك من الفقدان.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("نسخ احتياطي") { router.selected = .settings }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .vaultCard()
    }

    private func infoRow(icon: String, title: LocalizedStringKey, value: Text, tint: Color = Theme.accent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    // MARK: الإحصائيات

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(systemImage: "note.text", value: "\(notes.count)", title: "ملاحظات")
            StatTile(systemImage: "photo.on.rectangle", value: "\(media.count)", title: "وسائط", tint: Color(hex: 0x00A8E8))
            StatTile(
                systemImage: "internaldrive",
                value: ByteCountFormatter.string(fromByteCount: totalMediaBytes, countStyle: .file),
                title: "المساحة",
                tint: Theme.secure
            )
        }
    }

    // MARK: وصول سريع

    @ViewBuilder
    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "وصول سريع", actionTitle: "عرض الكل") {
                router.selected = .notes
            }

            if notes.isEmpty {
                Text("لا توجد ملاحظات بعد. اضغط + لإضافة أول ملاحظة.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vaultCard()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(notes.prefix(8)), id: \.objectID) { note in
                            NavigationLink {
                                NoteEditorView(note: note)
                            } label: {
                                NoteCard(note: note, lineLimit: 3, showsTags: false)
                                    .frame(width: 220, height: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: أحدث الوسائط

    @ViewBuilder
    private var recentMedia: some View {
        if !media.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "أحدث الوسائط", actionTitle: "عرض الكل") {
                    router.selected = .media
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(media.prefix(12)), id: \.objectID) { item in
                            Color(.secondarySystemBackground)
                                .frame(width: 96, height: 96)
                                .overlay {
                                    if item.managedObjectContext != nil, let image = ThumbnailCache.shared.image(for: item) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    }
                                }
                                .overlay(alignment: .bottomLeading) {
                                    if item.managedObjectContext != nil, item.kind == .video {
                                        Image(systemName: "play.circle.fill")
                                            .foregroundStyle(.white)
                                            .shadow(radius: 2)
                                            .padding(6)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { router.selected = .media }
                        }
                    }
                }
            }
        }
    }

    // MARK: نتائج البحث

    private var matchingNotes: [Note] {
        notes.filter { note in
            note.title.localizedCaseInsensitiveContains(query)
                || note.body.localizedCaseInsensitiveContains(query)
                || note.tagsRaw.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingMedia: [MediaItem] {
        media.filter { $0.originalFileName.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var searchResults: some View {
        let foundNotes = matchingNotes
        let foundMedia = matchingMedia

        VStack(alignment: .leading, spacing: 16) {
            if foundNotes.isEmpty && foundMedia.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "لا توجد نتائج",
                    message: "جرّب كلمات بحث مختلفة."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }

            if !foundNotes.isEmpty {
                SectionHeader(title: "الملاحظات")
                ForEach(foundNotes, id: \.objectID) { note in
                    NavigationLink {
                        NoteEditorView(note: note)
                    } label: {
                        NoteCard(note: note, lineLimit: 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !foundMedia.isEmpty {
                SectionHeader(title: "الوسائط")
                ForEach(foundMedia, id: \.objectID) { item in
                    Button {
                        router.selected = .media
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
                                .foregroundStyle(Theme.accent)
                            Text(verbatim: item.originalFileName)
                                .font(Theme.mono(.footnote))
                                .lineLimit(1)
                            Spacer()
                            Text(verbatim: item.formattedSize)
                                .font(Theme.mono(.caption2))
                                .foregroundStyle(.secondary)
                        }
                        .vaultCard(padding: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
}
