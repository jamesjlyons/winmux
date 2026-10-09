import SwiftUI

/// Keep typed text separate from the live value: parsing a partial number must
/// never reload configuration or rebuild the settings page while editing.
struct SettingsStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let help: String
    let save: () -> Void
    @State private var draft: String
    @State private var invalidSubmission = false
    @State private var sliderStartValue: Int?

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, help: String, save: @escaping () -> Void) {
        self.title = title
        _value = value
        self.range = range
        self.help = help
        self.save = save
        _draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: {
                value = Int($0.rounded())
                resetDraft()
            }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1) { editing in
                if editing {
                    sliderStartValue = value
                } else {
                    if let sliderStartValue, value != sliderStartValue { save() }
                    sliderStartValue = nil
                }
            }
            .frame(width: 96)
            .accessibilityLabel(title)
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .accessibilityLabel(title)
                .help(invalidSubmission
                    ? "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
                    : "Press Enter to apply.")
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(invalidSubmission ? Color.red : .clear, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .onSubmit(applyDraft)
            Stepper("", value: Binding(get: { value }, set: {
                let changed = value != $0
                value = $0
                resetDraft()
                if changed { save() }
            }), in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .help(help)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 14)
        }
        .onChange(of: value) { [value] newValue in
            // Refresh untouched fields after a reload without erasing a draft.
            if draft == String(value) { draft = String(newValue) }
        }
        .onChange(of: draft) { _ in invalidSubmission = false }
    }

    private func applyDraft() {
        guard let number = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(number) else {
            invalidSubmission = true
            return
        }
        let changed = value != number
        value = number
        resetDraft()
        if changed { save() }
    }

    private func resetDraft() {
        draft = String(value)
        invalidSubmission = false
    }
}
