import ShelloModel
import SwiftUI

/// Creates a tag from inside the host editor: a name and a colour from the tag palette. The tag is
/// stored with the host.
struct NewTagView: View {
    private let onAdd: (String, Tag.Color) -> Void
    @State private var name = ""
    @State private var color: Tag.Color
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool

    init(suggestedColor: Tag.Color, onAdd: @escaping (String, Tag.Color) -> Void) {
        self.onAdd = onAdd
        _color = State(initialValue: suggestedColor)
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                // Tag names are labels such as "k8s" or "Homelab", which autocorrection would change.
                TextField("Tag Name", text: $name, prompt: Text("e.g. Production"))
                    .accessibilityLabel("Tag Name")
                    .autocorrectionDisabled()
                    .focused($nameIsFocused)
                    .submitLabel(.done)
                    .onSubmit(add)
            } header: {
                SectionHeader("Name")
            }
            .listRowBackground(Palette.cell)

            Section {
                Picker("Color", selection: $color) {
                    ForEach(Tag.Color.allCases, id: \.self) { color in
                        ColorLabel(color: color, name: color.displayName)
                            .tag(color)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                SectionHeader("Color")
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("New Tag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", systemImage: "checkmark", role: .confirm, action: add)
                    .disabled(!canAdd)
                    .prominentToolbarButton()
            }
        }
        .onAppear { nameIsFocused = true }
    }

    private func add() {
        guard canAdd else { return }
        onAdd(name, color)
        dismiss()
    }
}
