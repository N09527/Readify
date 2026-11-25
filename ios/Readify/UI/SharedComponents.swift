import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ActiveDocumentPicker: String, Identifiable {
    case bookFiles
    case bookFolder
    case fontFiles
    case fontFolder

    var id: String { rawValue }
}

struct DocumentPickerRepresentable: UIViewControllerRepresentable {
    var mode: ActiveDocumentPicker
    var onPickURLs: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickURLs: onPickURLs, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let contentTypes: [UTType]
        let allowsMultiple: Bool
        let asCopy: Bool

        switch mode {
        case .bookFiles:
            contentTypes = [.item, .data]
            allowsMultiple = true
            asCopy = false
        case .bookFolder, .fontFolder:
            contentTypes = [.folder]
            allowsMultiple = false
            asCopy = false
        case .fontFiles:
            contentTypes = [.font, .item]
            allowsMultiple = true
            asCopy = false
        }

        let picker: UIDocumentPickerViewController
        if asCopy {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        }
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPickURLs: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPickURLs: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPickURLs = onPickURLs
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPickURLs(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

struct NumericSliderControl: View {
    let label: String
    let unit: String
    let value: Float
    let range: ClosedRange<Float>
    let decimals: Int
    let onValueChange: (Float) -> Void

    @State private var textValue: String = ""
    @FocusState private var isFocused: Bool

    private func formatVal(_ v: Float) -> String {
        if decimals == 0 {
            return "\(Int(v.rounded()))"
        }
        return String(format: "%.\(decimals)f", v)
    }

    private func commitText() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Float(trimmed) {
            let clamped = min(range.upperBound, max(range.lowerBound, parsed))
            onValueChange(clamped)
            textValue = formatVal(clamped)
        } else {
            textValue = formatVal(value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                HStack(spacing: 6) {
                    TextField("", text: $textValue)
                        .keyboardType(decimals > 0 ? .decimalPad : .numberPad)
                        .multilineTextAlignment(.center)
                        .font(.subheadline.weight(.medium))
                        .focused($isFocused)
                        .frame(width: 72, height: 32)
                        .background(Color(uiColor: .secondarySystemFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: textValue) { newVal in
                            let filtered = newVal.filter { $0.isNumber || (decimals > 0 && $0 == ".") }
                            if filtered.filter({ $0 == "." }).count <= 1 {
                                if filtered != newVal { textValue = filtered }
                                if let parsed = Float(filtered), range.contains(parsed) {
                                    onValueChange(parsed)
                                }
                            }
                        }
                        .onChange(of: isFocused) { focused in
                            if !focused { commitText() }
                        }

                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Slider(
                value: Binding(
                    get: { Double(min(range.upperBound, max(range.lowerBound, value))) },
                    set: { newV in
                        isFocused = false
                        let f = Float(newV)
                        onValueChange(f)
                        textValue = formatVal(f)
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
        .onAppear {
            textValue = formatVal(value)
        }
        .onChange(of: value) { newVal in
            if !isFocused {
                textValue = formatVal(newVal)
            }
        }
    }
}

struct SelectableChip: View {
    let label: String
    let selected: Bool
    var eInkMode: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        if eInkMode {
            return selected ? .black : .white
        }
        return selected ? Color.accentColor : Color(uiColor: .secondarySystemFill)
    }

    private var foregroundColor: Color {
        if eInkMode {
            return selected ? .white : .black
        }
        return selected ? .white : .primary
    }

    private var borderColor: Color {
        if eInkMode { return .black }
        return selected ? Color.accentColor : Color.secondary.opacity(0.25)
    }
}

struct BottomMenuActionButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TapZoneEditorSheet: View {
    let tapZones: [TapAction]
    var leftPresetTitle: String = "套用橫書預設"
    var rightPresetTitle: String = "套用直書預設"
    let onUpdateTapZones: ([TapAction]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("點一下任意格子即可輪流切換：上一頁 / 下一頁 / 選單")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { col in
                                let idx = row * 3 + col
                                let action = idx < tapZones.count ? tapZones[idx] : .TOGGLE_MENU
                                Button {
                                    var updated = tapZones.count == 9 ? tapZones : ReaderSettings.defaultVerticalTapZones()
                                    let next: TapAction
                                    switch action {
                                    case .PREV_PAGE: next = .NEXT_PAGE
                                    case .NEXT_PAGE: next = .TOGGLE_MENU
                                    case .TOGGLE_MENU: next = .PREV_PAGE
                                    }
                                    updated[idx] = next
                                    onUpdateTapZones(updated)
                                } label: {
                                    Text(action.label)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(Color(uiColor: UIColor(hex: 0x0F172A)))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 68)
                                        .background(cellColor(for: action))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color(uiColor: UIColor(hex: 0x94A3B8)), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        onUpdateTapZones(ReaderSettings.defaultHorizontalTapZones())
                    } label: {
                        Text(leftPresetTitle)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onUpdateTapZones(ReaderSettings.defaultVerticalTapZones())
                    } label: {
                        Text(rightPresetTitle)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("自訂九宮格點擊區域")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func cellColor(for action: TapAction) -> Color {
        switch action {
        case .PREV_PAGE: return Color(uiColor: UIColor(hex: 0xE0F2FE))
        case .NEXT_PAGE: return Color(uiColor: UIColor(hex: 0xDCFCE7))
        case .TOGGLE_MENU: return Color(uiColor: UIColor(hex: 0xFEF3C7))
        }
    }
}

struct ToastBannerView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.82))
            .clipShape(Capsule())
            .shadow(radius: 4)
    }
}
