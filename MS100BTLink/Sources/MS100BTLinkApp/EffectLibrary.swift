import SwiftUI
import ZoomCore

/// Full-window effect picker: categories on the left, effects drawn as mini stompboxes.
struct EffectLibrarySheet: View {
    @EnvironmentObject var model: LinkModel
    @Environment(\.dismiss) private var dismiss
    let slot: Int
    @State private var query = ""
    @State private var category: String? // nil = all

    struct Item: Identifiable {
        let id: UInt32
        let name: String
        let category: String
        let parameters: [String]
    }

    /// The MS-100BT's documented effects plus any effect already seen in this pedal's patches.
    private var allItems: [Item] {
        var ids = EffectCatalog.ms100btEffectIDs
        for p in model.slots.values { for e in p.effects where !e.isEmpty { ids.insert(e.effectID) } }
        for e in model.patch?.effects ?? [] where !e.isEmpty { ids.insert(e.effectID) }
        return ids.compactMap { id in
            guard let e = EffectCatalog.effect(for: id) else { return nil }
            return Item(id: id, name: e.name, category: EffectCatalog.category(for: id) ?? "Other",
                        parameters: e.parameters.map(\.name))
        }
        .sorted { $0.id < $1.id }
    }

    private var categories: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: allItems, by: \.category)
        return grouped.keys.sorted { (grouped[$0]!.first!.id >> 24) < (grouped[$1]!.first!.id >> 24) }
            .map { ($0, grouped[$0]!.count) }
    }

    private var sections: [(String, [Item])] {
        let filtered = allItems.filter {
            (category == nil || $0.category == category) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
             $0.parameters.contains { $0.localizedCaseInsensitiveContains(query) })
        }
        let grouped = Dictionary(grouping: filtered, by: \.category)
        return categories.map(\.name).compactMap { c in grouped[c].map { (c, $0) } }
    }

    var body: some View {
        let current = model.patch?.effects[slot]
        HStack(spacing: 0) {
            // Categories
            VStack(alignment: .leading, spacing: 4) {
                Text("Effects").font(.system(size: 22, weight: .bold, design: .rounded)).padding(.bottom, 8)
                categoryRow(nil, "All effects", allItems.count)
                ForEach(categories, id: \.name) { c in categoryRow(c.name, c.name, c.count) }
                Spacer()
                if current?.isEmpty == false {
                    Button(role: .destructive) {
                        Task { await model.setEffect(slot: slot, id: 0) }
                        dismiss()
                    } label: { Label("Remove from slot \(slot + 1)", systemImage: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.red.opacity(0.85))
                }
            }
            .padding(18)
            .frame(width: 210)
            .background(Theme.panel)

            // Grid
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                    TextField("Search effects or knobs (e.g. \"delay\", \"tone\")", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 15))
                    Spacer()
                    Text("Slot \(slot + 1)" + (current?.isEmpty == false ? " · now \(current!.displayName)" : " · empty"))
                        .font(.callout).foregroundStyle(Theme.dim)
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                .background(Theme.panel.opacity(0.6))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.0) { cat, items in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 160), spacing: 16)], spacing: 18) {
                                    ForEach(items) { item in
                                        EffectTile(item: item, isCurrent: current?.effectID == item.id)
                                            .onTapGesture {
                                                Task { await model.setEffect(slot: slot, id: item.id) }
                                                dismiss()
                                            }
                                    }
                                }
                                .padding(.horizontal, 18)
                            } header: {
                                HStack(spacing: 8) {
                                    Circle().fill(Theme.color(for: cat)).frame(width: 10, height: 10)
                                    Text(cat.uppercased()).font(.system(size: 12, weight: .heavy)).tracking(1.5)
                                    Text("\(items.count)").font(.caption).foregroundStyle(Theme.dim)
                                    Spacer()
                                }
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(Color(white: 0.09).opacity(0.95))
                            }
                        }
                        if sections.isEmpty {
                            Text("No effects match “\(query)”").foregroundStyle(Theme.dim).frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(width: 980, height: 660)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
    }

    private func categoryRow(_ value: String?, _ title: String, _ count: Int) -> some View {
        let on = category == value
        return HStack(spacing: 10) {
            Circle().fill(value.map { Theme.color(for: $0) } ?? Color.white.opacity(0.6)).frame(width: 9, height: 9)
            Text(title).font(.system(size: 13, weight: on ? .bold : .medium))
            Spacer()
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.dim)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(on ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { category = value }
    }
}

/// One effect drawn as a small stompbox: knobs for its first parameters, name, and knob names.
struct EffectTile: View {
    let item: EffectLibrarySheet.Item
    let isCurrent: Bool
    @State private var hover = false

    var body: some View {
        let color = Theme.color(for: item.category)
        let knobs = min(item.parameters.count, 3)
        VStack(spacing: 8) {
            PedalBody(color: color, corner: 14) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(0..<max(knobs, 1), id: \.self) { i in
                            KnobGlyph(angle: [-50, 20, 70][i % 3]).opacity(knobs == 0 ? 0 : 1)
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 8)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    LED(on: isCurrent || hover, size: 7)
                    Text(item.name)
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
                }
                .padding(.vertical, 14).padding(.horizontal, 10)
            }
            .frame(width: 128, height: 156)
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    Text("NOW").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white, in: Capsule()).foregroundStyle(.black).offset(x: 8, y: -8)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2).padding(-4))
            .scaleEffect(hover ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)

            Text(item.parameters.isEmpty ? "No controls" : item.parameters.prefix(4).joined(separator: " · ") + (item.parameters.count > 4 ? " …" : ""))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 140, height: 28, alignment: .top)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help("\(item.name) (\(item.category)): " + item.parameters.joined(separator: ", "))
    }
}

/// Small static knob drawing for tiles.
struct KnobGlyph: View {
    let angle: Double
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.35), Color(white: 0.1)], center: .init(x: 0.35, y: 0.3),
                                         startRadius: 1, endRadius: 14))
            Capsule().fill(Color.white).frame(width: 2, height: 7).offset(y: -5).rotationEffect(.degrees(angle))
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
    }
}
