import BlockerCore
import SafariServices
import SwiftUI

struct ContentView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case filters = "Filters"
        case userRules = "User Rules"
        case allowlist = "Allowlist"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "shield.lefthalf.filled"
            case .filters: "list.bullet.rectangle"
            case .userRules: "pencil.and.list.clipboard"
            case .allowlist: "checkmark.seal"
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
            }
        }
        .toolbar {
            ToolbarItem {
                if manager.isUpdating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(manager.progress).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button { Task { await manager.update(download: true) } } label: {
                        Label("Update Filters", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var manager: FilterManager

    private var allEnabled: Bool {
        BlockerCategory.allCases.allSatisfy { manager.statuses[$0]?.enabledInSafari == true }
            && manager.advanced.enabledInSafari
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !allEnabled {
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
                        Text("Filters updated \(date, style: .relative) ago")
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
                    Text(status?.enabledInSafari == true ? "On" : "Off in Safari")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(status?.enabledInSafari == true ? Color.green.opacity(0.2) : Color.orange.opacity(0.2),
                                    in: Capsule())
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

struct AdvancedCard: View {
    @EnvironmentObject private var manager: FilterManager
    let status: FilterManager.AdvancedStatus

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Advanced", systemImage: "wand.and.stars").font(.headline)
                    Spacer()
                    Text(status.enabledInSafari ? "On" : "Off in Safari")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(status.enabledInSafari ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
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
    @State private var dirty = false

    var body: some View {
        Form {
            ForEach(BlockerCategory.allCases) { category in
                let lists = manager.allLists.filter { $0.category == category }
                if !lists.isEmpty {
                    SwiftUI.Section(category.title) {
                        ForEach(lists) { list in
                            FilterRow(list: list, dirty: $dirty)
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
            if dirty {
                ToolbarItem {
                    Button("Apply") {
                        dirty = false
                        Task { await manager.update(download: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddListSheet { dirty = true } }
    }
}

struct FilterRow: View {
    @EnvironmentObject private var manager: FilterManager
    let list: FilterList
    @Binding var dirty: Bool

    var body: some View {
        let enabled = Binding(
            get: { manager.enabledIDs.contains(list.id) },
            set: { on in
                if on { manager.enabledIDs.insert(list.id) } else { manager.enabledIDs.remove(list.id) }
                dirty = true
            }
        )
        Toggle(isOn: enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                Text(list.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let error = manager.downloadErrors[list.id] {
                    Text("Download failed: \(error)").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            if list.isUserAdded {
                Button("Remove", role: .destructive) { manager.removeUserList(list); dirty = true }
            }
        }
    }
}

struct AddListSheet: View {
    @EnvironmentObject private var manager: FilterManager
    @Environment(\.dismiss) private var dismiss
    var onAdd: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var category: BlockerCategory = .custom

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("URL", text: $url, prompt: Text("https://example.com/filters.txt"))
            Picker("Content blocker", selection: $category) {
                ForEach(BlockerCategory.allCases) { Text($0.title).tag($0) }
            }
            Text("Each Safari content blocker holds at most 150,000 rules. Put large lists in a blocker with room.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else { return }
                    manager.addUserList(name: name.isEmpty ? parsed.host ?? url : name, url: parsed, category: category)
                    onAdd()
                    dismiss()
                }
                .disabled(URL(string: url)?.scheme?.hasPrefix("http") != true)
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

            HStack {
                Spacer()
                Button("Revert") { draft = manager.userRules }.disabled(draft == manager.userRules)
                Button("Save & Apply") {
                    manager.userRules = draft
                    Task { await manager.update(download: false) }
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

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack {
                    TextField("example.com", text: $newDomain)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(normalized.isEmpty)
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
                            manager.allowlist.removeAll { $0 == domain }
                            Task { await manager.update(download: false) }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Allowlist")
    }

    /// Accepts a bare domain or a pasted URL.
    private var normalized: String {
        let text = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        return URL(string: text)?.host ?? text.components(separatedBy: "/").first ?? ""
    }

    private func add() {
        let domain = normalized
        guard !domain.isEmpty, !manager.allowlist.contains(domain) else { return }
        manager.allowlist.append(domain)
        newDomain = ""
        Task { await manager.update(download: false) }
    }
}
