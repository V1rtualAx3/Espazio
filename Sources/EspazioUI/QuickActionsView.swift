import EspazioCore
import SwiftUI

/// Model of the Quick Actions palette (spec §3.8). Search is local and synchronous over a small
/// catalog of already-synchronized content.
@MainActor
@Observable
public final class QuickActionsModel {
    public var query = "" {
        didSet { refresh() }
    }
    public private(set) var results: [QuickActionItem] = []
    public var selection = 0
    public var catalog: [QuickActionItem] = [] {
        didSet { refresh() }
    }
    public var now: () -> Date = { Date() }

    public init() {}

    public func refresh() {
        results = QuickActionSearch.results(for: query, catalog: catalog, now: now())
        selection = min(selection, max(results.count - 1, 0))
    }

    public func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    public var selected: QuickActionItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }
}

public struct QuickActionsView: View {
    let model: QuickActionsModel
    let onExecute: (QuickActionItem) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    public init(model: QuickActionsModel, onExecute: @escaping (QuickActionItem) -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.onExecute = onExecute
        self.onClose = onClose
    }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Rechercher, ou « + titre demain 9h » pour un rappel", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit(executeSelection)
                    .onKeyPress(.downArrow) {
                        model.move(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.move(-1)
                        return .handled
                    }
                    .onExitCommand(perform: onClose)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            if !model.results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == model.selection)
                                    .id(item.id)
                                    .onTapGesture {
                                        model.selection = index
                                        executeSelection()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.selection) { _, _ in
                        if let id = model.selected?.id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .onAppear { focused = true }
    }

    private func row(_ item: QuickActionItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 20).foregroundStyle(selected ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func executeSelection() {
        guard let item = model.selected else { return }
        onExecute(item)
    }
}
