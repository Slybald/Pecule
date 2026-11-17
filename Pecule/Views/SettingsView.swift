import SwiftUI

// Five quick taps on the version row show the gateway settings, which an end user never needs.
enum DeveloperMode {
    static let key = "lifeos.developerModeEnabled"
    static let tapsToEnable = 5
    static let tapWindow: TimeInterval = 2
}

struct SettingsView: View {
    @EnvironmentObject private var localization: LocalizationManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var exportedFile: ExportedFile?
    @State private var exportError = false
    @StateObject private var csvExport = ExportCoordinator()
    @AppStorage(DeveloperMode.key) private var developerMode = false
    @State private var versionTaps = 0
    @State private var lastVersionTap = Date.distantPast

    var body: some View {
        List {
            Section {
                NavigationLink {
                    BudgetRulesView()
                } label: {
                    Label(AppLocalizer.string("settings.budgets.open", locale: locale), systemImage: "chart.pie")
                }
                .accessibilityIdentifier("settings-budgets-button")
            } header: {
                Text(AppLocalizer.string("settings.budgets.section", locale: locale))
            }

            BankAccountsSettingsSection(bankSync: appState.bankSync)
            if let signOut = appState.requestSignOut {
                Section {
                    Button(AppLocalizer.string("identity.signOut", locale: locale)) { Task { await signOut() } }
                        .accessibilityIdentifier("identity-sign-out")
                }
            }

            Section {
                Button {
                    Task { await csvExport.run { try await appState.csvExportInBackground() } }
                } label: {
                    HStack {
                        Label(AppLocalizer.string("settings.export.csv", locale: locale), systemImage: "tablecells")
                        if csvExport.isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(csvExport.isExporting)
                .accessibilityIdentifier("settings-export-csv-button")

                Button {
                    if let file = appState.pdfExport() {
                        exportedFile = file
                    } else {
                        exportError = true
                    }
                } label: {
                    Label(AppLocalizer.string("settings.export.pdf", locale: locale), systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("settings-export-pdf-button")
            } header: {
                Text(AppLocalizer.string("settings.export.section", locale: locale))
            } footer: {
                Text(AppLocalizer.string("settings.export.footer", locale: locale))
            }

            Section {
                Picker(
                    AppLocalizer.string("settings.language.title", locale: locale),
                    selection: Binding(
                        get: { localization.preferredLanguageCode ?? "" },
                        set: { localization.setLanguage($0.isEmpty ? nil : $0) }
                    )
                ) {
                    Text(AppLocalizer.string("settings.language.system", locale: locale))
                        .tag("")
                    ForEach(LocalizationManager.availableLanguages, id: \.code) { lang in
                        Text(AppLocalizer.string(lang.nameKey, locale: locale))
                            .tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings-language-picker")
            } header: {
                Text(AppLocalizer.string("settings.language.section", locale: locale))
            }

            Section {
                LabeledContent(AppLocalizer.string("settings.version", locale: locale), value: Self.versionText)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: registerVersionTap)
                    .accessibilityIdentifier("settings-version-row")
                if developerMode {
                    Button(AppLocalizer.string("settings.developer.disable", locale: locale)) {
                        developerMode = false
                    }
                    .accessibilityIdentifier("settings-developer-disable")
                }
            } header: {
                Text(AppLocalizer.string("settings.about", locale: locale))
            } footer: {
                if developerMode {
                    Text(AppLocalizer.string("settings.developer.enabled", locale: locale))
                        .accessibilityIdentifier("settings-developer-enabled")
                }
            }
        }
        .accessibilityIdentifier("settings-screen")
        .navigationTitle(AppLocalizer.string("settings.title", locale: locale))
        .sheet(item: $exportedFile) { file in
            ExportShareSheet(file: file)
        }
        .onChange(of: csvExport.file?.id) { _, _ in
            if let file = csvExport.file { exportedFile = file; csvExport.file = nil }
        }
        .alert(AppLocalizer.string("settings.export.error", locale: locale), isPresented: Binding(get: { exportError || csvExport.failed }, set: { if !$0 { exportError = false; csvExport.failed = false } })) {
            Button(AppLocalizer.string("OK", locale: locale), role: .cancel) {}
        }
    }
}

extension SettingsView {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func registerVersionTap() {
        let now = Date()
        versionTaps = now.timeIntervalSince(lastVersionTap) > DeveloperMode.tapWindow ? 1 : versionTaps + 1
        lastVersionTap = now
        guard versionTaps >= DeveloperMode.tapsToEnable, !developerMode else { return }
        developerMode = true
        versionTaps = 0
        AppHaptics.play(.success)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(LocalizationManager())
            .environmentObject(AppState.preview)
    }
}

private struct ExportShareSheet: View {
    let file: ExportedFile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.lg) {
                Image(systemName: file.contentType == .pdf ? "doc.richtext" : "tablecells")
                    .font(.system(size: 44))
                    .foregroundStyle(AppColors.accent)
                Text(file.fileName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(AppColors.primaryText)
                    .accessibilityIdentifier("export-file-name")
                Text(AppLocalizer.format("settings.export.size %@", locale: locale, ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)))
                    .font(AppTypography.rowMeta)
                    .foregroundStyle(AppColors.secondaryText)
                ShareLink(item: file, preview: SharePreview(file.fileName)) {
                    Label(AppLocalizer.string("settings.export.share", locale: locale), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("export-share-button")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.accent)
            }
            .padding(AppSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.groupedBackground.ignoresSafeArea())
            .navigationTitle(AppLocalizer.string("settings.export.section", locale: locale))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalizer.string("OK", locale: locale)) { dismiss() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("export-share-sheet")
        }
        .presentationDetents([.medium])
    }
}
