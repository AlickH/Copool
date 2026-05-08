import SwiftUI

struct AccountsPasteImportSheet: View {
    @Binding var text: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("accounts.paste_import.title"))
                .font(.title3.weight(.semibold))

            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 220)
                .background(editorBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if trimmedText.isEmpty {
                        Text(L10n.tr("accounts.paste_import.placeholder"))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Spacer()
                Button(L10n.tr("common.cancel"), action: onCancel)
                Button(L10n.tr("accounts.paste_import.submit"), action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedText.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(NSColor.textBackgroundColor))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.regularMaterial)
    }
}
