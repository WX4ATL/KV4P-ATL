// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct MemoriesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showingEditor = false
    @State private var showingRepeaterImport = false
    @State private var editingMemory: ChannelMemory?
    @State private var searchText = ""
    @State private var selectedGroup = "All"
    @State private var sortMode = MemorySortMode.name

    var body: some View {
        List {
            Section {
                groupSelector
                sortFilterControls
            }

            Section {
                if filteredMemories.isEmpty {
                    ContentUnavailableView("No memories", systemImage: "list.bullet.rectangle", description: Text("Add a channel or import a RepeaterBook CSV."))
                } else {
                    ForEach(filteredMemories) { memory in
                        Button {
                            app.tune(memory)
                        } label: {
                            MemoryRow(memory: memory, isActive: isActive(memory))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                app.tune(memory)
                            } label: {
                                Label("Set as voice channel", systemImage: "radio")
                            }
                            Button {
                                editingMemory = memory
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                app.deleteMemory(memory)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions {
                            Button {
                                editingMemory = memory
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)

                            Button(role: .destructive) {
                                app.deleteMemory(memory)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .safeAreaPadding(.bottom, 96)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search memories")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingRepeaterImport = true
                } label: {
                    Label("Find nearby repeaters", systemImage: "arrow.down.doc")
                }
                Button {
                    showingEditor = true
                } label: {
                    Label("Add memory", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            MemoryEditorView()
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorView(memory: memory)
        }
        .sheet(isPresented: $showingRepeaterImport) {
            RepeaterImportView()
        }
    }

    private var filteredMemories: [ChannelMemory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let grouped = app.memories.filter { memory in
            (selectedGroup == "All" ||
             (selectedGroup == "All memories" && memory.group.isEmpty) ||
             memory.group == selectedGroup)
        }
        let searched = query.isEmpty ? grouped : grouped.filter { memory in
            [memory.name, memory.group, String(format: "%.4f", memory.frequency)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return searched.sorted { first, second in
            switch sortMode {
            case .name:
                first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            case .frequency:
                first.frequency < second.frequency
            case .group:
                first.group.localizedCaseInsensitiveCompare(second.group) == .orderedAscending
            }
        }
    }

    private var memoryGroups: [String] {
        let groups = Set(app.memories.map { $0.group.isEmpty ? "All memories" : $0.group })
        return ["All"] + groups.sorted()
    }

    private var groupSelector: some View {
        Picker("Group", selection: $selectedGroup) {
            ForEach(memoryGroups, id: \.self) { group in
                Text(group).tag(group)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: app.memories) { _, _ in
            if !memoryGroups.contains(selectedGroup) {
                selectedGroup = "All"
            }
        }
    }

    private var sortFilterControls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(MemorySortMode.allCases) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        if sortMode == mode {
                            Label(mode.rawValue, systemImage: "checkmark")
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
    }

    private func isActive(_ memory: ChannelMemory) -> Bool {
        app.activeMemoryName == memory.name &&
        abs(app.activeRxFrequency - memory.frequency) < 0.0001 &&
        abs(app.activeTxFrequency - memory.txFrequency) < 0.0001
    }
}

private enum MemorySortMode: String, CaseIterable, Identifiable {
    case name = "Name"
    case frequency = "Frequency"
    case group = "Group"

    var id: String { rawValue }
}

struct MemoryRow: View {
    let memory: ChannelMemory
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(memory.group.isEmpty ? "All memories" : memory.group)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.4f", memory.frequency))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("TX \(String(format: "%.4f", memory.txFrequency))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { memoryBadges }
                VStack(alignment: .leading, spacing: 6) { memoryBadges }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var memoryBadges: some View {
        if isActive {
            KV4PBadge(text: "On radio", systemImage: "checkmark.circle.fill", tint: .green)
        }
        KV4PBadge(text: offsetLabel, systemImage: "arrow.left.arrow.right", tint: .secondary)
        if memory.txTone != "None" {
            KV4PBadge(text: "TX \(memory.txTone)", systemImage: "waveform", tint: .blue)
        }
        if memory.rxTone != "None" {
            KV4PBadge(text: "RX \(memory.rxTone)", systemImage: "ear", tint: .blue)
        }
    }

    private var offsetLabel: String {
        memory.offset == .none ? "Simplex" : "\(memory.offset == .down ? "-" : "+")\(memory.offsetKHz) kHz"
    }
}

struct RepeaterImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState
    @State private var group = "Nearby"
    @State private var repeaters: [RepeaterInfo] = []
    @State private var showingImporter = false
    @State private var status = "No CSV selected."

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Link(destination: URL(string: "https://www.repeaterbook.com/repeaters/prox.php")!) {
                        Label("RepeaterBook search", systemImage: "safari")
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import CSV", systemImage: "doc.badge.plus")
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Import") {
                    TextField("Memory group", text: $group)
                    Button {
                        app.importRepeaters(repeaters, group: group.isEmpty ? "Nearby" : group)
                        dismiss()
                    } label: {
                        Label("Save \(repeaters.count) repeaters", systemImage: "square.and.arrow.down")
                    }
                    .disabled(repeaters.isEmpty)
                }

                Section("Preview") {
                    if repeaters.isEmpty {
                        ContentUnavailableView("No CSV loaded", systemImage: "antenna.radiowaves.left.and.right", description: Text(status))
                    } else {
                        ForEach(repeaters.prefix(30)) { repeater in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(repeater.callsign.isEmpty ? "Repeater" : repeater.callsign)
                                        .font(.headline)
                                    Spacer()
                                    Text(String(format: "%.4f", repeater.frequency))
                                        .font(.system(.body, design: .monospaced))
                                }
                                Text("\(repeater.location), \(repeater.state) - \(offsetLabel(repeater.offsetMHz)) - TX \(repeater.tone)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Repeaters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                importCSV(result)
            }
        }
    }

    private func importCSV(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let allowed = url.startAccessingSecurityScopedResource()
            defer {
                if allowed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let csv = try String(contentsOf: url, encoding: .utf8)
            let minFrequency = app.firmwareVersion?.minFrequency ?? 0
            let maxFrequency = app.firmwareVersion?.maxFrequency ?? 1_000
            repeaters = RepeaterBookCSVParser.parse(csv, minFrequency: minFrequency, maxFrequency: maxFrequency)
            status = repeaters.isEmpty ? "No supported repeater rows found in that CSV." : "Loaded \(repeaters.count) repeaters."
        } catch {
            status = error.localizedDescription
        }
    }

    private func offsetLabel(_ offset: Float) -> String {
        if offset == 0 { return "simplex" }
        return String(format: "%+.3f MHz", offset)
    }
}

struct MemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppState
    private let editingMemory: ChannelMemory?
    @State private var name = ""
    @State private var group = ""
    @State private var frequency = "146.5200"
    @State private var offset = ChannelMemory.Offset.none
    @State private var offsetKHz = 600
    @State private var txTone = "None"
    @State private var rxTone = "None"

    init(memory: ChannelMemory? = nil) {
        editingMemory = memory
        _name = State(initialValue: memory?.name ?? "")
        _group = State(initialValue: memory?.group ?? "")
        _frequency = State(initialValue: memory.map { String(format: "%.4f", $0.frequency) } ?? "146.5200")
        _offset = State(initialValue: memory?.offset ?? .none)
        _offsetKHz = State(initialValue: memory?.offsetKHz ?? 600)
        _txTone = State(initialValue: memory?.txTone ?? "None")
        _rxTone = State(initialValue: memory?.rxTone ?? "None")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel") {
                    TextField("Name", text: $name)
                    TextField("Group", text: $group)
                    TextField("RX frequency", text: $frequency)
                        .keyboardType(.decimalPad)
                }

                Section("Repeater") {
                    Picker("Offset", selection: $offset) {
                        Text("None").tag(ChannelMemory.Offset.none)
                        Text("Down").tag(ChannelMemory.Offset.down)
                        Text("Up").tag(ChannelMemory.Offset.up)
                    }
                    Stepper("Offset \(offsetKHz) kHz", value: $offsetKHz, in: 0...5_000, step: 5)
                    Picker("TX tone", selection: $txTone) {
                        ForEach(RadioToneHelper.validToneStrings, id: \.self) { tone in
                            Text(tone).tag(tone)
                        }
                    }
                    Picker("RX tone", selection: $rxTone) {
                        ForEach(RadioToneHelper.validToneStrings, id: \.self) { tone in
                            Text(tone).tag(tone)
                        }
                    }
                }
            }
            .navigationTitle(editingMemory == nil ? "Add Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var memory = ChannelMemory(
                            name: name.isEmpty ? "Memory" : name,
                            group: group,
                            frequency: Float(frequency) ?? 146.5200,
                            offset: offset,
                            offsetKHz: offsetKHz,
                            txTone: txTone,
                            rxTone: rxTone,
                            skipDuringScan: false
                        )
                        if let editingMemory {
                            memory.id = editingMemory.id
                            app.updateMemory(memory)
                        } else {
                            app.addMemory(memory)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
