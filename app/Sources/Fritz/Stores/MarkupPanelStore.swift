import AppKit
import NativeMarkupDevelopment
import NativeMarkupUI
import Observation
import UniformTypeIdentifiers

/// Owns the panel's document and bindings independently of its visibility.
@MainActor @Observable final class MarkupPanelStore {
    let loader = MarkupFileLoader()
    let session: MarkupSession
    var note = ""
    var enabled = true
    private var presentationDiagnostic: String?

    @ObservationIgnored private var filePanel: NSOpenPanel?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var lastAppliedSource: String?

    init() {
        let context = MarkupContext()
        session = MarkupSession(context: context)
        context.registerBinding("note",
            get: { [weak self] in self?.note ?? "" },
            set: { [weak self] in self?.note = $0 }
        )
        context.registerBinding("enabled",
            get: { [weak self] in self?.enabled ?? false },
            set: { [weak self] in self?.enabled = $0 }
        )
        context.registerAction("clear") { [weak self] in self?.note = "" }
        synchronizeSource()
    }

    var diagnostic: String? { presentationDiagnostic ?? loader.diagnostic ?? session.diagnostic }
    var filename: String { loader.fileURL?.lastPathComponent ?? "Sample" }
    var status: String {
        if diagnostic != nil { return "Error" }
        return loader.fileURL == nil ? "Sample" : "Live"
    }

    func synchronizeSource() {
        let source = loader.source ?? Self.sample
        guard source != lastAppliedSource else { return }
        lastAppliedSource = source
        session.apply(source: source)
    }

    func chooseFile(in window: NSWindow?) {
        guard filePanel == nil else { return }
        guard let window else {
            presentationDiagnostic = "Open the Fritz window, then choose Open Markup again."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open Markup"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.xml]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.preventsApplicationTerminationWhenModal = false
        filePanel = panel
        presentationDiagnostic = nil
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.filePanel === panel else { return }
            self.filePanel = nil
            guard response == .OK, let url = panel.url else { return }
            self.openTask?.cancel()
            let loader = self.loader
            self.openTask = Task { await loader.open(url) }
        }
    }

    func stop() {
        filePanel?.cancel(nil)
        filePanel = nil
        openTask?.cancel()
        openTask = nil
        loader.stop()
    }

    static let sample = """
        <Interface version="1">
          <VStack id="panel" spacing="12" alignment="leading">
            <Text id="heading" value="Scratchpad"/>
            <TextField id="note-field" title="Note" text="$note"/>
            <Toggle id="enabled" title="Enabled" isOn="$enabled"/>
            <Text id="preview" value="$note"/>
            <Button id="clear" title="Clear" action="clear">
              <Modifiers>
                <Disabled value="{{ !enabled || isEmpty(note) }}"/>
              </Modifiers>
            </Button>
          </VStack>
        </Interface>
        """
}
