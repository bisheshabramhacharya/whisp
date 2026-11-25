import AppKit
import Combine
import SwiftUI
import WhispCore

@MainActor
final class DailyDataSession: ObservableObject {
    let store: DailyDataStore
    let history: HistoryStore
    let dictionary: DailyDictionary
    @Published private(set) var folder = ""
    @Published private(set) var syncStatus = ""
    @Published private(set) var refresh = 0
    @Published private(set) var microphone = ""
    @Published private(set) var working = false
    @Published var error: String?
    private var timer: AnyCancellable?

    init(root: URL) {
        store = DailyDataStore(file: root.appendingPathComponent("daily-data.json"))
        history = HistoryStore(fileURL: root.appendingPathComponent("history.jsonl"), daily: store)
        dictionary = DailyDictionary(store: store)
        do {
            try history.importLegacy()
            try dictionary.importLegacy(root.appendingPathComponent("dictionary.json"))
            folder = try preference("folder")
            microphone = try preference("microphone")
        } catch { self.error = error.localizedDescription }
        sync()
        timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.sync()
        }
    }

    private func preference(_ id: String) throws -> String {
        try store.records("local").first { $0.id == id }?.value ?? ""
    }

    func selectMicrophone(_ id: String) {
        attempt {
            try store.update([.init("local", "microphone", id)])
            microphone = id
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { selectFolder(url.path) }
    }

    func selectFolder(_ path: String) {
        attempt {
            try store.update([.init("local", "folder", path)])
            folder = path
            syncStatus = ""
            sync()
        }
    }

    func sync() {
        guard !folder.isEmpty, !working else { return }
        working = true
        let folder = self.folder, store = self.store
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try store.sync(with: URL(fileURLWithPath: folder, isDirectory: true)) }
            }.value
            working = false
            guard self.folder == folder else { return }
            switch result {
            case .success(0): syncStatus = "Last synced at \(Date().formatted(date: .omitted, time: .shortened))."
            case .success(let count): syncStatus = "\(count) unreadable sync file(s). Whisp will retry."
            case .failure(let error): syncStatus = "Couldn't sync: \(error.localizedDescription). Local data is still available."
            }
            refresh += 1
        }
    }

    func attempt(_ action: () throws -> Void) {
        do { try action(); refresh += 1 }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class DailyDataWindow: NSWindowController {
    enum Page: Hashable { case history, dictionary, microphone, sync }

    init(session: DailyDataSession, page: Page) {
        let controller = NSHostingController(rootView: DailyDataView(session: session, page: page))
        let window = NSWindow(contentViewController: controller)
        window.title = "Whisp Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 670, height: 460))
        window.minSize = NSSize(width: 580, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
private struct DailyDataView: View {
    @ObservedObject var session: DailyDataSession
    @State var page: DailyDataWindow.Page
    @State private var historyQuery = ""
    @State private var history: [HistoryEntry] = []
    @State private var historyID: String?
    @State private var text = ""
    @State private var dictionaryQuery = ""
    @State private var dictionary: [DailyDataStore.Record] = []
    @State private var wordID: String?
    @State private var heard = ""
    @State private var replacement = ""
    @State private var inputs: [MicrophoneDevice] = []
    @State private var confirmRemove = false

    init(session: DailyDataSession, page: DailyDataWindow.Page) {
        self.session = session
        _page = State(initialValue: page)
    }

    var body: some View {
        TabView(selection: $page) {
            historyTab.tabItem { Text("History") }.tag(DailyDataWindow.Page.history)
            dictionaryTab.tabItem { Text("Dictionary") }.tag(DailyDataWindow.Page.dictionary)
            microphoneTab.tabItem { Text("Microphone") }.tag(DailyDataWindow.Page.microphone)
            syncTab.tabItem { Text("Sync") }.tag(DailyDataWindow.Page.sync)
        }
        .padding(12)
        .onAppear { reload(); inputs = MicrophoneDevice.available() }
        .onChange(of: session.refresh) { _, _ in reload() }
        .onChange(of: historyQuery) { _, _ in reload() }
        .onChange(of: dictionaryQuery) { _, _ in reload() }
        .onChange(of: historyID) { _, id in text = history.first { $0.id == id }?.cleaned ?? "" }
        .onChange(of: wordID) { _, id in
            let entry = dictionary.first { $0.id == id }
            heard = entry?.value ?? ""
            replacement = entry?.detail ?? ""
        }
        .alert("Whisp couldn't finish", isPresented: Binding(
            get: { session.error != nil }, set: { if !$0 { session.error = nil } }
        )) {
            Button("OK", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    private var historyTab: some View {
        VStack(alignment: .leading) {
            TextField("Search dictations", text: $historyQuery)
            HSplitView {
                List(history, selection: $historyID) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.cleaned.isEmpty ? entry.raw : entry.cleaned).lineLimit(2)
                        Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    }.tag(entry.id)
                }.frame(minWidth: 200)
                if let current = history.first(where: { $0.id == historyID }) {
                    VStack(alignment: .leading) {
                        Text("Dictation text").font(.headline)
                        TextEditor(text: $text).accessibilityLabel("Dictation text").border(.quaternary)
                        HStack {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                            Spacer()
                            Button("Save") { session.attempt { try session.history.edit(id: current.id, text: text) } }
                                .disabled(text == current.cleaned)
                        }
                    }.padding(8).frame(minWidth: 240)
                } else {
                    Text(history.isEmpty ? "No matching dictations." : "Select a dictation to edit or copy it.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding()
    }

    private var dictionaryTab: some View {
        VStack(alignment: .leading) {
            TextField("Search words and replacements", text: $dictionaryQuery)
            HSplitView {
                List(dictionary, selection: $wordID) { entry in
                    Text(entry.detail.isEmpty ? entry.value : "\(entry.value) → \(entry.detail)").tag(entry.id)
                }.frame(minWidth: 200)
                VStack(alignment: .leading, spacing: 8) {
                    Text(wordID == nil ? "New dictionary entry" : "Edit dictionary entry").font(.headline)
                    TextField("Word or heard phrase", text: $heard)
                    TextField("Replace with (optional)", text: $replacement)
                    Text("Leave the replacement blank to preserve a word's capitalization.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("New") { wordID = nil; heard = ""; replacement = "" }
                        Button("Remove", role: .destructive) { confirmRemove = true }.disabled(wordID == nil)
                        Spacer()
                        Button(wordID == nil ? "Add" : "Save") {
                            session.attempt {
                                if try !session.dictionary.save(id: wordID, from: heard, to: replacement) {
                                    session.error = "This entry is already in your dictionary."
                                } else if wordID == nil { heard = ""; replacement = "" }
                            }
                        }.disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Spacer()
                }.padding(8).frame(minWidth: 265)
            }
        }.padding().confirmationDialog("Remove this dictionary entry?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                if let wordID { session.attempt { try session.dictionary.remove(id: wordID); self.wordID = nil } }
            }
        }
    }

    private var microphoneTab: some View {
        Form {
            Picker("Input device", selection: Binding(get: { session.microphone }, set: session.selectMicrophone)) {
                Text("System Default").tag("")
                if !session.microphone.isEmpty, !inputs.contains(where: { $0.id == session.microphone }) {
                    Text("Selected microphone (unavailable)").tag(session.microphone)
                }
                ForEach(inputs) { Text($0.name).tag($0.id) }
            }
            Button("Refresh Devices") { inputs = MicrophoneDevice.available() }
            Button("Open System Sound Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text("Applies to the next dictation. If the selected device is unplugged, Whisp uses the system default. Your choice stays on this Mac.")
                .foregroundStyle(.secondary)
        }.padding()
    }

    private var syncTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folder sync").font(.headline)
            Text("Choose the same synced folder on each device. Whisp syncs dictation text and dictionary entries without a Whisp account. Audio recordings and microphone choices stay on this device.")
            Text("The folder contains readable dictation text. Only choose a folder you trust.")
                .foregroundStyle(.secondary)
            Text(session.folder.isEmpty ? "Sync is off." : session.folder).textSelection(.enabled)
            HStack {
                Button("Choose Folder…", action: session.chooseFolder).disabled(session.working)
                Button("Sync Now", action: session.sync).disabled(session.folder.isEmpty || session.working)
                Button("Disconnect") { session.selectFolder("") }.disabled(session.folder.isEmpty || session.working)
            }
            Text(session.working ? "Syncing…" : session.syncStatus).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }

    private func reload() {
        do {
            history = try session.history.search(historyQuery)
            dictionary = try session.dictionary.records(matching: dictionaryQuery)
        } catch { session.error = error.localizedDescription }
    }
}
