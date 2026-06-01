import SwiftUI

struct RubricEditorView: View {
    @Bindable var assignment: Assignment
    @Binding var isPresented: Bool

    @State private var newName = ""
    @State private var newMax = ""

    private var sorted: [RubricItem] {
        assignment.rubricItems.sorted(by: { $0.order < $1.order })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rubric — \(assignment.name)")
                .font(.headline)
                .padding()

            Divider()

            List {
                ForEach(sorted) { item in
                    RubricRowEditor(item: item) {
                        assignment.rubricItems.removeAll { $0.id == item.id }
                    }
                }
                .onMove { from, to in
                    var items = sorted
                    items.move(fromOffsets: from, toOffset: to)
                    for (idx, item) in items.enumerated() { item.order = idx }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 200)

            Divider()

            // Add row
            HStack(spacing: 8) {
                TextField("Problem name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                TextField("Pts", text: $newMax)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Button("Add") { addItem() }
                    .disabled(newName.isEmpty || Double(newMax) == nil)
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 420, height: 460)
    }

    private func addItem() {
        guard !newName.isEmpty, let max = Double(newMax) else { return }
        let order = (assignment.rubricItems.map(\.order).max() ?? -1) + 1
        assignment.rubricItems.append(RubricItem(name: newName, maxPoints: max, order: order))
        newName = ""
        newMax = ""
    }
}

struct RubricRowEditor: View {
    @Bindable var item: RubricItem
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            TextField("Name", text: $item.name)
            Spacer()
            TextField("Pts", value: $item.maxPoints, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 50)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }
}
