//
//  MainTabView.swift
//  SecureVault
//
//  آيفون: شريط تبويب سفلي (4 تبويبات) + زر إضافة عائم.
//  آيباد (عرض عريض): قائمة جانبية NavigationSplitView + نفس الزر العائم.
//

import SwiftUI
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
}

struct MainTabView: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var context

    @StateObject private var router = AppRouter()
    @StateObject private var importer = MediaImportViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                SidebarRootView()
            } else {
                PhoneTabView()
            }
        }
        .environmentObject(router)
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
