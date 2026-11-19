//
//  MainTabView.swift
//  SecureVault
//
//  آيفون: شريط تبويب سفلي (4 تبويبات) + زر إضافة عائم.
//  آيباد (عرض عريض): قائمة جانبية NavigationSplitView + نفس الزر العائم.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case notes
    case media
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: return "الرئيسية"
        case .notes:     return "الملاحظات"
        case .media:     return "الوسائط"
        case .settings:  return "الإعدادات"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .notes:     return "note.text"
        case .media:     return "photo.on.rectangle.angled"
        case .settings:  return "gearshape.fill"
        }
    }

    @ViewBuilder
    var rootView: some View {
        switch self {
        case .dashboard: DashboardView()
        case .notes:     NotesView()
        case .media:     MediaGalleryView()
        case .settings:  SettingsBackupView()
        }
    }
}

/// حالة التنقل المشتركة بين الأقسام والزر العائم.
@MainActor
final class AppRouter: ObservableObject {
    @Published var selected: AppSection = .dashboard
    @Published var showNewNote = false
    @Published var showPhotoPicker = false
    /// ملفات ملاحظات اختارها المستخدم من منتقي الملفات (تُعالَج في MainTabView).
    @Published var pickedNoteURLs: [URL] = []
    @Published var pasteNoteRequested = false
}

struct MainTabView: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @EnvironmentObject private var router: AppRouter
    @StateObject private var importer = MediaImportViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var noteImportMessage: String?

    private func reportNoteImport(_ summary: NoteImportSummary) {
        var parts: [String] = []
        if summary.imported > 0 {
            parts.append(String(format: String(localized: "تم استيراد %lld ملاحظة"), Int(summary.imported)))
        }
        if summary.failed > 0 {
            parts.append(String(format: String(localized: "تعذّر استيراد %lld عنصر (فارغ أو غير مدعوم)"), Int(summary.failed)))
        }
        noteImportMessage = parts.joined(separator: "\n")
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                SidebarRootView()
            } else {
                PhoneTabView()
            }
        }
        .environmentObject(importer)
        .overlay(alignment: .bottomTrailing) {
            if router.selected != .settings {
                FloatingAddButton()
                    .padding(.trailing, 20)
                    .padding(.bottom, horizontalSizeClass == .regular ? 28 : 70)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: router.selected)
        .sheet(isPresented: $router.showNewNote) {
            NavigationStack {
                NoteEditorView(note: nil)
            }
            .environment(\.managedObjectContext, context)
            .environmentObject(router)
        }
        .overlay(alignment: .bottom) {
            ImportStatusView()
                .padding(.bottom, horizontalSizeClass == .regular ? 100 : 140)
        }
        .onChange(of: router.pickedNoteURLs) { urls in
            guard !urls.isEmpty else { return }
            router.pickedNoteURLs = []
            reportNoteImport(NoteImporter.importFiles(urls, into: context))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { FileImportCenter.shared.refreshPending() }
        }
        .onChange(of: router.pasteNoteRequested) { requested in
            guard requested else { return }
            router.pasteNoteRequested = false
            reportNoteImport(NoteImporter.importFromClipboard(into: context))
        }
        .alert("استيراد الملاحظات", isPresented: Binding(
            get: { noteImportMessage != nil },
            set: { if !$0 { noteImportMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: noteImportMessage ?? "")
        }
        .photosPicker(
            isPresented: $router.showPhotoPicker,
            selection: $pickerItems,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty else { return }
            Task {
                await importer.importItems(items, context: context)
                pickerItems = []
            }
        }
        .alert("الاستيراد", isPresented: Binding(
            get: { importer.resultMessage != nil },
            set: { if !$0 { importer.resultMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: importer.resultMessage ?? "")
        }
    }
}

// MARK: - الزر العائم

private struct FloatingAddButton: View {

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var fileImport = FileImportCenter.shared

    private func importMedia(folder: Bool) {
        guard let container = environment.persistence?.container else { return }
        DocumentPickerPresenter.present(
            types: folder ? [.folder] : [.image, .movie],
            asCopy: false,
            allowsMultipleSelection: !folder
        ) { urls in
            router.selected = .media
            FileImportCenter.shared.start(picked: urls, container: container)
        }
    }

    var body: some View {
        Menu {
            Button {
                router.showNewNote = true
            } label: {
                Label("ملاحظة جديدة", systemImage: "square.and.pencil")
            }

            Button {
                router.showPhotoPicker = true
            } label: {
                Label("استيراد صور وفيديو", systemImage: "photo.badge.plus")
            }

            Button {
                importMedia(folder: false)
            } label: {
                Label("استيراد صور وفيديو من الملفات", systemImage: "doc.badge.plus")
            }
            .disabled(fileImport.isBusy)

            Button {
                importMedia(folder: true)
            } label: {
                Label("استيراد مجلد كامل من الملفات", systemImage: "folder.badge.plus")
            }
            .disabled(fileImport.isBusy)

            Button {
                DocumentPickerPresenter.present(
                    types: NoteImporter.contentTypes,
                    asCopy: true,
                    allowsMultipleSelection: true
                ) { urls in
                    router.pickedNoteURLs = urls
                }
            } label: {
                Label("استيراد ملاحظات من ملفات", systemImage: "square.and.arrow.down")
            }

            Button {
                router.pasteNoteRequested = true
            } label: {
                Label("لصق ملاحظة من الحافظة", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [Theme.accent, Color(hex: 0x00A8E8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .shadow(color: Theme.accent.opacity(0.45), radius: 12, y: 6)
        }
        .accessibilityLabel(Text("إضافة"))
    }
}

// MARK: - آيفون

private struct PhoneTabView: View {

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.selected) {
            ForEach(AppSection.allCases) { section in
                NavigationStack {
                    section.rootView
                }
                .tabItem {
                    Label(section.title, systemImage: section.systemImage)
                }
                .tag(section)
            }
        }
    }
}

// MARK: - آيباد

private struct SidebarRootView: View {

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var auth: BiometricAuthManager

    var body: some View {
        NavigationSplitView {
            List(
                AppSection.allCases,
                selection: Binding<AppSection?>(
                    get: { router.selected },
                    set: { if let value = $0 { router.selected = value } }
                )
            ) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("الخزنة")
            .safeAreaInset(edge: .bottom) {
                Button {
                    auth.lock()
                } label: {
                    Label("قفل الآن", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding()
            }
        } detail: {
            NavigationStack {
                router.selected.rootView
            }
            .id(router.selected)
        }
    }
}
