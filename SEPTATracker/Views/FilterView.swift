import SwiftUI

struct FilterView: View {
    @EnvironmentObject private var store: VehicleStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Show") {
                    ForEach(TransitMode.allCases) { mode in
                        Toggle(isOn: modeBinding(mode)) {
                            Label(mode.title, systemImage: mode.systemImage)
                                .foregroundStyle(mode.tint)
                        }
                    }
                }

                Section {
                    Button("All routes") { store.selectedRoutes.removeAll() }
                        .disabled(store.selectedRoutes.isEmpty)
                } footer: {
                    Text("Only routes with vehicles reporting right now are listed.")
                }

                ForEach(TransitMode.allCases.filter { store.enabledModes.contains($0) }) { mode in
                    let routes = filtered(store.routes(for: mode))
                    if !routes.isEmpty {
                        Section(mode.title) {
                            ForEach(routes, id: \.self) { route in
                                Button {
                                    toggle(route)
                                } label: {
                                    HStack {
                                        Text(route).foregroundStyle(.primary)
                                        Spacer()
                                        if store.selectedRoutes.contains(route) {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $search, prompt: "Route")
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .keyboardDismissButton()
    }

    private func filtered(_ routes: [String]) -> [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return routes }
        return routes.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func toggle(_ route: String) {
        if store.selectedRoutes.contains(route) {
            store.selectedRoutes.remove(route)
        } else {
            store.selectedRoutes.insert(route)
        }
    }

    private func modeBinding(_ mode: TransitMode) -> Binding<Bool> {
        Binding(
            get: { store.enabledModes.contains(mode) },
            set: { isOn in
                if isOn { store.enabledModes.insert(mode) } else { store.enabledModes.remove(mode) }
            }
        )
    }
}
