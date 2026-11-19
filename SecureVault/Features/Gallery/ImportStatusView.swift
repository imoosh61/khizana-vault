//
//  ImportStatusView.swift
//  SecureVault
//
//  بطاقة عائمة تُظهر تقدّم استيراد الملفات في أي تبويب، وتعرض الملفات المنتظرة للاستئناف.
//

import SwiftUI

struct ImportStatusView: View {

    @ObservedObject private var center = FileImportCenter.shared
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmDiscard = false

    var body: some View {
        VStack {
            if center.isBusy {
                progressCard
            } else if center.pendingCount > 0 {
                pendingCard
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.isBusy)
        .animation(.easeInOut(duration: 0.2), value: center.pendingCount)
        .onAppear { center.refreshPending() }
        .alert("الاستيراد", isPresented: Binding(
            get: { center.resultMessage != nil },
            set: { if !$0 { center.resultMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: center.resultMessage ?? "")
        }
        .confirmationDialog(
            "حذف الملفات المنتظرة؟ (الأصل يبقى في تطبيق الملفات)",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("حذفها", role: .destructive) { center.discardPending() }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private var phaseTitle: LocalizedStringKey {
        switch center.phase {
        case .idle, .scanning: return "جارٍ فحص الملفات…"
        case .transferring:    return "جارٍ نقل الملفات إلى التطبيق"
        case .processing:      return "جارٍ إضافة الملفات إلى الخزنة"
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(phaseTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("إيقاف", role: .destructive) { center.stop() }
                    .font(.subheadline)
            }

            if center.total > 0 {
                ProgressView(value: Double(center.completed), total: Double(max(center.total, 1)))
                HStack {
                    Text(verbatim: "\(center.completed) / \(center.total)")
                        .monospacedDigit()
                    Spacer()
                    Text(verbatim: center.currentName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            Text("أبقِ التطبيق مفتوحاً حتى ينتهي الاستيراد")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(center.pendingCount) ملف بانتظار الإضافة إلى الخزنة")
                .font(.subheadline.weight(.semibold))
            HStack {
                Button("متابعة") {
                    if let container = environment.persistence?.container {
                        center.resume(container: container)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("حذفها", role: .destructive) { confirmDiscard = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
