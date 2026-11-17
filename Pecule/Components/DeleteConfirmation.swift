import SwiftUI

extension View {
    // A swipe never deletes on its own: it sets `item`, and this asks first. Cancel keeps it.
    func deleteConfirmation<Item>(
        _ item: Binding<Item?>,
        name: @escaping (Item) -> String,
        perform: @escaping (Item) -> Void
    ) -> some View {
        modifier(DeleteConfirmation(item: item, name: name, perform: perform))
    }
}

private struct DeleteConfirmation<Item>: ViewModifier {
    @Binding var item: Item?
    let name: (Item) -> String
    let perform: (Item) -> Void
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        // An alert, like the account unlink: it always shows both choices, and its buttons keep their identifiers.
        content.alert(
            item.map { AppLocalizer.format("delete.confirm.title %@", locale: locale, name($0)) } ?? "",
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            presenting: item
        ) { value in
            Button(AppLocalizer.string("Delete", locale: locale), role: .destructive) { perform(value) }
                .accessibilityIdentifier("delete-confirm-button")
            Button(AppLocalizer.string("Cancel", locale: locale), role: .cancel) {}
                .accessibilityIdentifier("delete-cancel-button")
        } message: { _ in
            Text(AppLocalizer.string("delete.confirm.message", locale: locale))
        }
    }
}
