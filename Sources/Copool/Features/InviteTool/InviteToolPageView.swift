import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct InviteToolPageView: View {
    @ObservedObject var model: InviteToolPageModel

    private let resultColumns = [
        GridItem(.adaptive(minimum: 140), alignment: .leading),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutRules.sectionSpacing) {
                formSection
                resultsSection
            }
            .padding(LayoutRules.pagePadding)
        }
        .scrollIndicators(.hidden)
    }

    private var formSection: some View {
        SectionCard(title: "卡密工具") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("操作", selection: $model.selectedOperation) {
                    ForEach(InviteToolOperation.allCases) { operation in
                        Text(operation.title).tag(operation)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.currentOperationDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.showsDefaultEmailField {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.currentDefaultEmailTitle)
                            .font(.subheadline.weight(.medium))
                        TextField(
                            model.selectedOperation == .redeem ? "user@example.com" : "new-mail@example.com",
                            text: Binding(
                                get: { model.currentDefaultEmail },
                                set: { model.setCurrentDefaultEmail($0) }
                            )
                        )
                        .frostedRoundedInput()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("批量输入")
                        .font(.subheadline.weight(.medium))

                    BatchInputEditor(
                        text: Binding(
                            get: { model.currentInputText },
                            set: { model.setCurrentInput($0) }
                        ),
                        placeholder: editorPlaceholder
                    )
                    .frame(minHeight: LayoutRules.inviteToolEditorHeight)
                }

                HStack(spacing: 10) {
                    Button("填充示例") {
                        model.fillSampleInput()
                    }
                    .liquidGlassActionButtonStyle()

                    Button("清空输入") {
                        model.clearCurrentInput()
                    }
                    .liquidGlassActionButtonStyle()

                    Spacer(minLength: 0)

                    Button(model.selectedOperation.runButtonTitle) {
                        model.runSelectedOperation()
                    }
                    .liquidGlassActionButtonStyle(prominent: true)
                    .disabled(model.loading)
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        SectionCard(title: "执行结果") {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = model.currentSummary {
                    summaryPills(summary)
                }

                switch model.resultsState {
                case .loading:
                    ProgressView("正在执行批量请求…")
                        .frame(maxWidth: .infinity, minHeight: 140)
                case .empty(let message):
                    EmptyStateView(title: "暂无结果", message: message)
                case .error(let message):
                    EmptyStateView(title: "执行失败", message: message)
                case .content(let rows):
                    if rows.isEmpty {
                        EmptyStateView(title: "暂无结果", message: "没有可展示的结果。")
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(rows) { row in
                                resultRow(row)
                            }
                        }
                    }
                }
            }
        }
    }

    private func summaryPills(_ summary: InviteToolSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summaryPill("总计 \(summary.total)", tint: .blue)
                summaryPill("成功 \(summary.successCount)", tint: .green)
                summaryPill("需处理 \(summary.warningCount)", tint: .orange)
                summaryPill("失败 \(summary.errorCount)", tint: .red)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    summaryPill("总计 \(summary.total)", tint: .blue)
                    summaryPill("成功 \(summary.successCount)", tint: .green)
                }
                HStack(spacing: 8) {
                    summaryPill("需处理 \(summary.warningCount)", tint: .orange)
                    summaryPill("失败 \(summary.errorCount)", tint: .red)
                }
            }
        }
    }

    private func summaryPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frostedCapsuleSurface(prominent: true, tint: tint)
    }

    private func resultRow(_ row: InviteToolResultRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.code)
                        .font(.headline)
                    Text(row.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(row.tone.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frostedCapsuleSurface(prominent: true, tint: resultTint(for: row.tone))
            }

            LazyVGrid(columns: resultColumns, alignment: .leading, spacing: 8) {
                ForEach(row.detailItems, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.1)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .cardSurface(cornerRadius: 10, tint: resultTint(for: row.tone).opacity(0.08))
                }
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 12, tint: resultTint(for: row.tone).opacity(0.06))
    }

    private func resultTint(for tone: InviteToolResultTone) -> Color {
        switch tone {
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var editorPlaceholder: String {
        switch model.selectedOperation {
        case .redeem:
            return """
            Z-EXAMPLE001,user1@example.com
            Z-EXAMPLE002 user2@example.com
            Z-EXAMPLE003
            """
        case .warranty:
            return """
            Z-EXAMPLE001
            Z-EXAMPLE002,new-mail@example.com
            """
        case .status:
            return """
            Z-EXAMPLE001
            Z-EXAMPLE002
            """
        }
    }
}

private struct BatchInputEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            BatchInputTextView(text: $text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.body.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, LayoutRules.inviteToolEditorTextHorizontalInset)
                    .padding(.vertical, LayoutRules.inviteToolEditorTextVerticalInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .frostedRoundedSurface(cornerRadius: LayoutRules.inviteToolEditorCornerRadius)
    }
}

private struct BatchInputTextView: View {
    @Binding var text: String

    var body: some View {
        #if canImport(AppKit)
        BatchInputMacTextView(text: $text)
        #else
        TextEditor(text: $text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(.horizontal, LayoutRules.inviteToolEditorTextHorizontalInset - 4)
            .padding(.vertical, LayoutRules.inviteToolEditorTextVerticalInset - 4)
        #endif
    }
}

#if canImport(AppKit)
private struct BatchInputMacTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(
            width: LayoutRules.inviteToolEditorTextHorizontalInset,
            height: LayoutRules.inviteToolEditorTextVerticalInset
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        textView.textContainerInset = NSSize(
            width: LayoutRules.inviteToolEditorTextHorizontalInset,
            height: LayoutRules.inviteToolEditorTextVerticalInset
        )
        textView.textContainer?.lineFragmentPadding = 0
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
        }
    }
}
#endif
