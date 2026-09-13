import SwiftUI
import AppKit
import FinderRescueCore

struct StartupTab: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", problems = "Problems", on = "On", off = "Off"
        var id: String { rawValue }
    }

    @State private var items: [LaunchItem] = []
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var errorText: String?
    @State private var loading = false
    @State private var selection: LaunchItem.ID?

    private var shown: [LaunchItem] {
        items.filter { matches($0, filter) }.filter {
            search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)
                || $0.command.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text("\(f.rawValue) (\(items.filter { matches($0, f) }.count))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 400)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
            }
            Table(shown, selection: $selection) {
                TableColumn("On") { item in
                    Toggle("On", isOn: Binding(get: { item.enabled }, set: { v in Task { await toggle(item, v) } }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!item.editable)
                }
                .width(44)
                TableColumn("Name") { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).lineLimit(1)
                        Text(item.command).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .help(item.command)
                }
                TableColumn("Where") { item in Text(item.scope.rawValue).foregroundStyle(.secondary) }.width(95)
                TableColumn("Runs") { item in Text(item.schedule) }.width(120)
                TableColumn("Status") { item in Text(item.status) }.width(105)
                TableColumn("Problem") { item in
                    Text(item.problem ?? "").foregroundStyle(.red).lineLimit(1).help(item.problem ?? "")
                }
                .width(min: 120, ideal: 190)
            }
            .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
                if let path = ids.first {
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                }
            }
            Group {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else {
                    Text("Turning off one of your own agents unloads it and moves its file to ~/Library/LaunchAgents-disabled-FinderRescue, so you can turn it back on at any time. \"All users\" agents are turned off for your account only. System daemons can't be changed here.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding()
        .task { await reload() }
    }

    private func matches(_ item: LaunchItem, _ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .problems: return item.problem != nil
        case .on: return item.enabled
        case .off: return !item.enabled
        }
    }

    private func reload() async {
        loading = true
        items = await offMain { StartupItems.scan() }
        loading = false
    }

    private func toggle(_ item: LaunchItem, _ on: Bool) async {
        errorText = await offMain { () -> String? in
            do {
                try StartupItems.setEnabled(item, on)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        await reload()
    }
}

struct ExtensionsTab: View {
    @EnvironmentObject var m: FinderMonitor
    @State private var extensions: [FinderExtension] = []
    @State private var changed = false

    var body: some View {
        Form {
            Section {
                ForEach(extensions) { ext in
                    Toggle(isOn: Binding(get: { ext.enabled }, set: { v in Task { await set(ext, v) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ext.appName)
                            Text("\(ext.kind) · \(ext.id)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(ext.isApple)
                }
            } header: {
                Text("Apps plugged into Finder")
            } footer: {
                Text("Cloud-storage apps and Finder add-ons run code whenever Finder shows files, and a misbehaving one can slow every Finder window. Turning one off stops that app working inside Finder; nothing already in the cloud is deleted. Apple's own extensions can't be changed here.")
            }
            if changed {
                Section {
                    HStack {
                        Text("Relaunch Finder to apply the change everywhere.")
                        Spacer()
                        Button("Relaunch Finder") {
                            m.rescue(reason: "Relaunched after changing extensions", automatic: false)
                            changed = false
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        extensions = await offMain { Extensions.scan() }
    }

    private func set(_ ext: FinderExtension, _ on: Bool) async {
        await offMain { Extensions.setEnabled(ext, on) }
        changed = true
        await reload()
    }
}

struct LogTab: View {
    @EnvironmentObject var m: FinderMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.events.isEmpty {
                ContentUnavailableView("No rescues yet", systemImage: "checkmark.seal",
                                       description: Text("Every Finder relaunch, automatic or manual, is listed here with a diagnostic sample when one was saved."))
            } else {
                List(m.events) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.automatic ? "bolt.fill" : "hand.tap")
                            .foregroundStyle(event.automatic ? .orange : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.reason)
                            Text("\(Fmt.dateTime.string(from: event.date)) · CPU \(Int(event.cpu))% · \(Fmt.mb(event.footprintMB))\(event.automatic ? " · automatic" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let path = event.samplePath, FileManager.default.fileExists(atPath: path) {
                            Button("Open sample") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Text("\(m.events.count) relaunch\(m.events.count == 1 ? "" : "es") recorded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Log") { m.clearLog() }.disabled(m.events.isEmpty)
                Button("Open Log Folder") { NSWorkspace.shared.open(RescueLog.dir) }
            }
        }
        .padding()
    }
}
