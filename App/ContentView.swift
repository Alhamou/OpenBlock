import BlockerCore
import SafariServices
import SwiftUI

struct ContentView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case filters = "Filters"
        case userRules = "User Rules"
        case allowlist = "Allowlist"
        case settings = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "shield.lefthalf.filled"
            case .filters: "list.bullet.rectangle"
            case .userRules: "pencil.and.list.clipboard"
            case .allowlist: "checkmark.seal"
            case .settings: "gearshape"
            }
        }
    }

    @EnvironmentObject private var manager: FilterManager
    @State private var section: Section? = .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch section ?? .overview {
            case .overview: OverviewView()
            case .filters: FiltersView()
            case .userRules: UserRulesView()
            case .allowlist: AllowlistView()
            case .settings: SettingsView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if manager.isUpdating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(manager.progress).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if manager.pendingApply {
                        Button { Task { await manager.applyPendingChanges() } } label: {
                            Label("Apply Changes", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Download new lists and rebuild the Safari rules")
                    }
                    Button { Task { await manager.update(download: .all) } } label: {
                        Label("Update Filters", systemImage: "arrow.clockwise")
                    }
                    .help("Download every enabled list again")
                }
            }
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var manager: FilterManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if manager.isPaused {
                    GroupBox {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Blocking is paused").font(.headline)
                                Text("Safari loads every page without OpenBlock's rules until you resume.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") { Task { await manager.setPaused(false) } }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                if !manager.allEnabledInSafari {
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Turn on OpenBlock in Safari").font(.headline)
                                Text("Safari → Settings → Extensions → enable the four “OpenBlock” content blockers and “OpenBlock Advanced”. "
                                     + "Then click the OpenBlock icon in Safari's toolbar and choose “Always Allow on Every Website”.")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Open Safari Extensions") { manager.openSafariSettings() }
                                    Button("Check Again") { Task { await manager.refreshSafariState() } }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(BlockerCategory.allCases) { category in
                        BlockerCard(category: category, status: manager.statuses[category])
                    }
                    AdvancedCard(status: manager.advanced)
                }

                Group {
                    if let date = manager.lastUpdate {
                        Text("Filters updated \(date, style: .relative) ago · next check within 24 hours while OpenBlock runs")
                    } else {
                        Text("Filters have not been downloaded yet")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }
}

struct BlockerCard: View {
    let category: BlockerCategory
    let status: FilterManager.BlockerStatus?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(category.title, systemImage: category.symbol).font(.headline)
                    Spacer()
                    StatusBadge(on: status?.enabledInSafari == true)
                }
                let stats = status?.stats ?? ConversionStats()
                Text("\(stats.safariRules.formatted()) Safari rules")
                    .font(.title3.monospacedDigit())
                ProgressView(value: Double(stats.safariRules), total: Double(Converter.safariRuleLimit))
                    .tint(stats.truncated > 0 ? .red : .accentColor)
                Text("\(stats.advancedRules.formatted()) advanced rules go to OpenBlock Advanced · "
                     + "\(stats.unsupportedRules.formatted()) unsupported")
                    .font(.caption).foregroundStyle(.secondary)
                if stats.truncated > 0 {
                    Text("\(stats.truncated.formatted()) rules dropped: Safari allows 150,000 per blocker. Disable an overlapping list.")
                        .font(.caption).foregroundStyle(.red)
                }
                if let error = status?.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct StatusBadge: View {
    let on: Bool

    var body: some View {
        Text(on ? "On" : "Off in Safari")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
    }
}

struct AdvancedCard: View {
    @EnvironmentObject private var manager: FilterManager
    let status: FilterManager.AdvancedStatus

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Advanced", systemImage: "wand.and.stars").font(.headline)
                    Spacer()
                    StatusBadge(on: status.enabledInSafari)
                }
                Text("\(status.stats.rules.formatted()) in-page rules").font(.title3.monospacedDigit())
                Text("Scriptlets, CSS injection and extended CSS (for example YouTube ads and anti-adblock walls). "
                     + "\(status.stats.unsupported.formatted()) unsupported · "
                     + "\(status.stats.untrustedRejected.formatted()) JavaScript rules rejected from untrusted lists")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if !status.enabledInSafari {
                    Button("Enable OpenBlock Advanced…") {
                        SFSafariApplication.showPreferencesForExtension(withIdentifier: FilterManager.advancedExtensionID)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

// MARK: - Filters

struct FiltersView: View {
    @EnvironmentObject private var manager: FilterManager
    @State private var showingAdd = false

    var body: some View {
        Form {
            if manager.pendingApply {
                SwiftUI.Section {
                    Label("List changes take effect when you click “Apply Changes” in the toolbar.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(BlockerCategory.allCases) { category in
                let lists = manager.allLists.filter { $0.category == category }
                if !lists.isEmpty {
                    SwiftUI.Section(category.title) {
                        ForEach(lists) { list in
                            FilterRow(list: list)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Filters")
        .toolbar {
            ToolbarItem {
                Button { showingAdd = true } label: { Label("Add Filter List", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) { AddListSheet() }
    }
}

struct FilterRow: View {
    @EnvironmentObject private var manager: FilterManager
    let list: FilterList

    var body: some View {
        let enabled = Binding(
            get: { manager.enabledIDs.contains(list.id) },
            set: { manager.setEnabled($0, for: list) }
        )
        Toggle(isOn: enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                Text(list.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let info = manager.listInfo[list.id] {
                    Text("\(info.ruleCount.formatted()) rules · downloaded \(info.downloadedAt, style: .relative) ago")
                        .font(.caption).foregroundStyle(.tertiary)
                } else if enabled.wrappedValue {
                    Text("Not downloaded yet").font(.caption).foregroundStyle(.tertiary)
                }
                if let error = manager.downloadErrors[list.id] {
                    Text("Download failed: \(error)").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            if list.isUserAdded {
                Button("Remove", role: .destructive) { manager.removeUserList(list) }
            }
        }
    }
}

struct AddListSheet: View {
    @EnvironmentObject private var manager: FilterManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var category: BlockerCategory = .custom

    private var parsedURL: URL? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), parsed.scheme?.hasPrefix("http") == true,
              parsed.host != nil else { return nil }
        return parsed
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("URL", text: $url, prompt: Text("https://example.com/filters.txt"))
            Picker("Content blocker", selection: $category) {
                ForEach(BlockerCategory.allCases) { Text($0.title).tag($0) }
            }
            Text("AdBlock syntax and hosts files (`0.0.0.0 ads.example.com`) are supported. "
                 + "Each Safari content blocker holds at most 150,000 rules; put large lists in a blocker with room.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    guard let parsed = parsedURL else { return }
                    manager.addUserList(name: name.isEmpty ? parsed.host ?? url : name, url: parsed, category: category)
                    dismiss()
                }
                .disabled(parsedURL == nil)
            }
        }
    }
}

// MARK: - User rules

struct UserRulesView: View {
    @EnvironmentObject private var manager: FilterManager
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("""
            AdBlock syntax, one rule per line. Examples:
            ||ads.example.com^        block a domain
            example.com##.sidebar-ad  hide an element
            @@||example.com/ad.js     allow a request
            """)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            let report = manager.userRulesReport
            if draft == manager.userRules, report.rules + report.unsupported > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(report.rules.formatted()) rules in use · \(report.unsupported.formatted()) not supported")
                        .font(.caption)
                        .foregroundStyle(report.unsupported > 0 ? Color.orange : Color.secondary)
                    ForEach(Array(report.issues.prefix(8).enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.line)   (\(issue.reason))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                    if report.unsupported > 8 {
                        Text("and \(report.unsupported - 8) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Revert") { draft = manager.userRules }.disabled(draft == manager.userRules)
                Button("Save & Apply") {
                    manager.userRules = draft
                    Task { await manager.update(download: .none) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == manager.userRules)
            }
        }
        .padding(20)
        .navigationTitle("User Rules")
        .onAppear { draft = manager.userRules }
    }
}

// MARK: - Allowlist

struct AllowlistView: View {
    @EnvironmentObject private var manager: FilterManager
    @State private var newDomain = ""

    private var trimmed: String { newDomain.trimmingCharacters(in: .whitespaces) }
    private var normalized: String? { FilterManager.normalizedAllowlistEntry(newDomain) }

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    TextField("example.com", text: $newDomain)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(normalized == nil)
                }
                if !trimmed.isEmpty, normalized == nil {
                    Text("Enter a domain such as example.com (a pasted link works too).")
                        .font(.caption).foregroundStyle(.red)
                } else if let domain = normalized, manager.allowlist.contains(domain) {
                    Text("\(domain) is already allowed.").font(.caption).foregroundStyle(.secondary)
                } else if let domain = normalized, domain != trimmed.lowercased() {
                    Text("Will be added as \(domain)").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("OpenBlock does not block anything on these sites or their subdomains.")
            }
            SwiftUI.Section("Allowed sites") {
                if manager.allowlist.isEmpty {
                    Text("No sites").foregroundStyle(.secondary)
                }
                ForEach(manager.allowlist, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await manager.removeAllowlistEntry(domain) }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Allowlist")
    }

    private func add() {
        guard let domain = normalized, !manager.allowlist.contains(domain) else { return }
        newDomain = ""
        Task { await manager.addAllowlistEntry(domain) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var manager: FilterManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            SwiftUI.Section("Blocking") {
                Toggle("Pause blocking", isOn: Binding(
                    get: { manager.isPaused },
                    set: { paused in Task { await manager.setPaused(paused) } }
                ))
                Text("Safari loads pages without OpenBlock's rules while paused. Useful when a site breaks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("App") {
                Toggle("Keep OpenBlock in the menu bar only", isOn: $settings.menuBarOnly)
                Text("The Dock icon appears only while this window is open. Closing the window leaves OpenBlock "
                     + "running in the menu bar, where filters keep updating every 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let note = settings.launchAtLoginNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            SwiftUI.Section("Filters") {
                LabeledContent("Automatic updates", value: "Every 24 hours while OpenBlock runs")
                if let date = manager.lastUpdate {
                    LabeledContent("Last update", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Update Filters Now") { Task { await manager.update(download: .all) } }
                    .disabled(manager.isUpdating)
            }
            SwiftUI.Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("License", value: "GPL-3.0")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}
