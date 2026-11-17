import SwiftUI

struct CategorySelectionView: View {
    @Binding var selection: String
    let identifier: String
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var showsCreation = false
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        Picker(AppLocalizer.string("Category", locale: locale), selection: $selection) {
            ForEach(appState.availableCategories) { category in
                Text(category.displayName(locale: locale)).tag(category.storageValue)
            }
            if !appState.availableCategories.contains(where: { $0.storageValue == selection }) {
                Text(ExpenseCategory.displayName(forStoredValue: selection, locale: locale)).tag(selection)
            }
        }.accessibilityIdentifier(identifier)
        Button(AppLocalizer.string("category.create", locale: locale)) { showsCreation = true }
            .accessibilityIdentifier(identifier + "-create")
            .alert(AppLocalizer.string("category.create", locale: locale), isPresented: $showsCreation) {
                TextField(AppLocalizer.string("Name", locale: locale), text: $name)
                Button(AppLocalizer.string("Save", locale: locale)) {
                    guard appState.isProfileActive else { return }
                    do {
                        let category = try appState.dataStore.createCategory(name: name)
                        appState.reload(); selection = category.storageValue; name = ""
                    } catch { errorMessage = error.userMessage }
                }
                Button(AppLocalizer.string("Cancel", locale: locale), role: .cancel) {}
            }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
    }
}

struct CategoryCatalogView: View {
    @State private var selection = ExpenseCategory.other.storageValue
    @Environment(\.locale) private var locale
    var body: some View {
        Form { CategorySelectionView(selection: $selection, identifier: "catalog-category") }
            .navigationTitle(AppLocalizer.string("category.manage", locale: locale))
    }
}
