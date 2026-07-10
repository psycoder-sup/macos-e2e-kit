import SwiftUI

/// The demo's observable model: the list of items plus the text-field input that feeds it.
@MainActor
final class ItemsModel: ObservableObject {
    @Published var items: [String] = []
    @Published var input: String = ""

    /// The trimmed input, or nil when it's empty/whitespace — drives the Add button's enabled state.
    var trimmedInput: String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func addItem() {
        guard let trimmed = trimmedInput else { return }
        items.append(trimmed)
        input = ""
    }

    func clearInput() {
        input = ""
    }
}

/// A tiny UI that exercises every driver verb: a text field (type/set_value), an Add button
/// (perform + ⌘Return key equivalent), a Clear button (Escape key equivalent), a list of rows, and a
/// count label. Every control carries an accessibility identifier so tests can address it.
struct ContentView: View {
    @ObservedObject var model: ItemsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("New item", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("demo.input")

                // Escape clears the field.
                Button("Clear input") { model.clearInput() }
                    .accessibilityIdentifier("demo.clear")
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Add") { model.addItem() }
                    .accessibilityIdentifier("demo.add")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.trimmedInput == nil)
            }

            List {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    // Wrap each row's Text so it carries a stable, index-based identifier in the AX
                    // tree (demo.row.0, demo.row.1, …).
                    Text(item)
                        .accessibilityIdentifier("demo.row.\(index)")
                }
            }

            Text("\(model.items.count) items")
                .accessibilityIdentifier("demo.count")
        }
        .padding()
        .frame(minWidth: 400, minHeight: 440)
    }
}
