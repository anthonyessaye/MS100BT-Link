import Foundation

/// Provider-neutral logic behind the AI patch builder's tools: effect lookup, patch
/// descriptions, and turning a model's proposed patch (JSON) into a validated `PatchEdit`.
/// Nothing here talks to the pedal; the app decides when (and whether) to send.
public enum PatchAssistant {
    public struct SpecError: Error, CustomStringConvertible {
        public let problems: [String]
        public var description: String { problems.joined(separator: "\n") }
    }

    // MARK: effect catalog views

    /// Effects that can be offered: the MS-100BT's documented set plus any ID seen on this pedal.
    public static func availableIDs(seen: [PatchDump]) -> Set<UInt32> {
        var ids = EffectCatalog.ms100btEffectIDs
        for p in seen { for e in p.effects where !e.isEmpty { ids.insert(e.effectID) } }
        return ids
    }

    /// Compact list for the model: name, category, knob names.
    public static func effectList(available: Set<UInt32>, category: String? = nil) -> [[String: Any]] {
        available.sorted().compactMap { id -> [String: Any]? in
            guard let e = EffectCatalog.effect(for: id) else { return nil }
            let cat = EffectCatalog.category(for: id) ?? "Other"
            if let category, cat.caseInsensitiveCompare(category) != .orderedSame { return nil }
            return ["name": e.name, "category": cat, "knobs": e.parameters.map(\.name)]
        }
    }

    /// Full knob details (allowed values, defaults) for the named effects.
    public static func effectDetails(names: [String], available: Set<UInt32>) -> [[String: Any]] {
        names.map { n in
            guard let id = lookup(n, available: available), let e = EffectCatalog.effect(for: id) else {
                return ["name": n, "error": "Unknown effect. Use list_effects for valid names." + suggestion(n, available)]
            }
            return [
                "name": e.name,
                "category": EffectCatalog.category(for: id) ?? "Other",
                "knobs": e.parameters.map { p -> [String: Any] in
                    ["name": p.name, "values": describeValues(p), "default": p.display(p.defaultRaw) ?? "\(p.defaultRaw)"]
                },
            ]
        }
    }

    /// Human/model-readable value range, e.g. "1–30", ["OFF","ON"], "1–4000, then 𝅘𝅥, 𝅘𝅥 x2 …".
    public static func describeValues(_ p: EffectCatalog.Parameter) -> Any {
        let all = (0..<p.valueCount).compactMap { p.display($0) }
        if all.count <= 16 && all.contains(where: { Int($0) == nil }) { return all }
        var parts: [String] = []
        var i = 0
        while i < all.count {
            if let start = Int(all[i]) {
                var j = i
                while j + 1 < all.count, Int(all[j + 1]) == Int(all[j])! + 1 { j += 1 }
                parts.append(j > i ? "\(start)–\(all[j])" : all[i])
                i = j + 1
            } else {
                parts.append(all[i]); i += 1
            }
        }
        if parts.count > 14 { parts = Array(parts.prefix(12)) + ["… (\(all.count) values total)"] }
        return parts.joined(separator: ", ")
    }

    // MARK: patch descriptions

    public static func describe(_ p: PatchDump, slot: Int? = nil) -> [String: Any] {
        var d: [String: Any] = [
            "name": p.name ?? "",
            "tempo_bpm": p.tempo ?? 0,
            "effects": p.effects.filter { !$0.isEmpty }.map { e -> [String: Any] in
                var params: [String: String] = [:]
                for v in e.parameters { params[v.name] = v.text }
                return ["slot": e.index + 1, "effect": e.displayName, "category": e.category ?? "",
                        "on": e.isOn == true, "params": params]
            },
        ]
        if let slot { d["memory_slot"] = slot + 1 }
        return d
    }

    // MARK: building patches

    /// Builds a complete patch from a model's spec, on top of `base` (which supplies the bits
    /// the decoder doesn't model). Spec:
    /// `{"name": "...", "tempo": 120, "effects": [{"effect": "Hall", "on": true, "params": {"Decay": 12}}]}`
    /// Effects are placed in signal order in slots 1…n; remaining slots are emptied.
    public static func buildPatch(spec: [String: Any], base: PatchDump, available: Set<UInt32>) -> Result<PatchEdit, SpecError> {
        var problems: [String] = []
        var edit = PatchEdit(base)

        if let name = spec["name"] as? String {
            let clean = String(name.unicodeScalars.filter { PatchEdit.nameCharacters.contains($0) })
            if clean.count > 10 { problems.append("name \"\(name)\" is longer than 10 characters") }
            if clean != name { problems.append("name may only use plain ASCII characters") }
            edit.setName(clean)
        }
        if let t = number(spec["tempo"]) {
            if !PatchEdit.tempoRange.contains(t) { problems.append("tempo \(t) is outside 40–250 BPM") }
            edit.setTempo(t)
        }

        guard let effects = spec["effects"] as? [[String: Any]] else {
            return .failure(SpecError(problems: problems + ["\"effects\" must be a list of 1–6 effects in signal order"]))
        }
        if effects.isEmpty { problems.append("a patch needs at least one effect") }
        if effects.count > PatchDump.effectCount { problems.append("the MS-100BT has \(PatchDump.effectCount) slots; got \(effects.count) effects") }

        for (slot, fx) in effects.prefix(PatchDump.effectCount).enumerated() {
            guard let name = fx["effect"] as? String, let id = lookup(name, available: available),
                  let def = EffectCatalog.effect(for: id) else {
                let n = fx["effect"] as? String ?? "?"
                problems.append("slot \(slot + 1): unknown effect \"\(n)\"." + suggestion(n, available))
                continue
            }
            let on = (fx["on"] as? Bool) ?? true
            edit.setEffect(slot: slot, id: id, on: on)
            for (key, value) in (fx["params"] as? [String: Any]) ?? [:] {
                guard let idx = def.parameters.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                    problems.append("slot \(slot + 1) \(def.name): no knob named \"\(key)\" (knobs: \(def.parameters.map(\.name).joined(separator: ", ")))")
                    continue
                }
                switch raw(for: value, def.parameters[idx]) {
                case .success(let r): edit.setParameter(slot: slot, index: idx, raw: r)
                case .failure(let why): problems.append("slot \(slot + 1) \(def.name) \(def.parameters[idx].name): \(why)")
                }
            }
        }
        for slot in effects.count..<PatchDump.effectCount { edit.setEffect(slot: slot, id: 0) }

        if problems.isEmpty, let problem = edit.decoded?.validationProblem { problems.append(problem) }
        return problems.isEmpty ? .success(edit) : .failure(SpecError(problems: problems))
    }

    /// Applies knob/on-off changes to an existing patch:
    /// `[{"slot": 2, "param": "Mix", "value": 40}, {"slot": 3, "on": false}]`.
    public static func adjust(_ changes: [[String: Any]], base: PatchDump) -> Result<PatchEdit, SpecError> {
        var problems: [String] = []
        var edit = PatchEdit(base)
        for c in changes {
            guard let slotNo = number(c["slot"]), (1...PatchDump.effectCount).contains(slotNo) else {
                problems.append("each change needs \"slot\" 1–6"); continue
            }
            let fx = base.effects[slotNo - 1]
            guard !fx.isEmpty, let def = EffectCatalog.effect(for: fx.effectID) else {
                problems.append("slot \(slotNo) is empty; use propose_patch to add effects"); continue
            }
            if let on = c["on"] as? Bool { edit.setOn(slot: slotNo - 1, on) }
            if let key = c["param"] as? String {
                guard let idx = def.parameters.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                    problems.append("slot \(slotNo) \(def.name): no knob named \"\(key)\""); continue
                }
                switch raw(for: c["value"] as Any, def.parameters[idx]) {
                case .success(let r): edit.setParameter(slot: slotNo - 1, index: idx, raw: r)
                case .failure(let why): problems.append("slot \(slotNo) \(def.name) \(key): \(why)")
                }
            }
        }
        if problems.isEmpty, let problem = edit.decoded?.validationProblem { problems.append(problem) }
        return problems.isEmpty ? .success(edit) : .failure(SpecError(problems: problems))
    }

    // MARK: helpers

    /// Raw value for a display value given as a number or string ("50", 50, "TRI 1", "on").
    public static func raw(for value: Any, _ p: EffectCatalog.Parameter) -> Result<Int, SpecError> {
        let wanted: String
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            wanted = n.doubleValue.rounded() == n.doubleValue ? String(n.intValue) : n.stringValue
        } else if let b = value as? Bool {
            wanted = b ? "ON" : "OFF"
        } else if let s = value as? String {
            wanted = s.trimmingCharacters(in: .whitespaces)
        } else {
            return .failure(SpecError(problems: ["value missing"]))
        }
        for i in 0..<p.valueCount where p.display(i)?.caseInsensitiveCompare(wanted) == .orderedSame {
            return .success(i)
        }
        let range = describeValues(p)
        let text = (range as? [String])?.joined(separator: ", ") ?? "\(range)"
        return .failure(SpecError(problems: ["\"\(wanted)\" is not allowed (values: \(text))"]))
    }

    /// Case- and punctuation-insensitive effect name match, preferring available IDs.
    public static func lookup(_ name: String, available: Set<UInt32>) -> UInt32? {
        let key = normalize(name)
        let matches = EffectCatalog.effects.filter { normalize($0.value.name) == key }.map(\.key).sorted()
        return matches.first(where: available.contains)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func suggestion(_ name: String, _ available: Set<UInt32>) -> String {
        let key = normalize(name)
        guard key.count >= 3 else { return "" }
        let close = available.compactMap { EffectCatalog.name(for: $0) }
            .filter { normalize($0).contains(key.prefix(4)) || key.contains(normalize($0)) }
            .sorted().prefix(5)
        return close.isEmpty ? "" : " Did you mean: \(close.joined(separator: ", "))?"
    }

    private static func number(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
