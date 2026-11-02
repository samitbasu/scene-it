import AppKit
import SceneItCore
import SwiftUI

@Observable
final class ReportModel {
    enum State {
        case preparing
        case ready(ProblemReport)
        case failed(String)
    }

    private(set) var state = State.preparing
    private(set) var notice: String?
    @ObservationIgnored var close: () -> Void = {}
    private let inputs: ProblemReport.Inputs

    init(inputs: ProblemReport.Inputs) {
        self.inputs = inputs
    }

    func prepare() async {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "Scene It Reports/\(UUID().uuidString)", directoryHint: .isDirectory)
        state = .preparing
        state = await Self.build(inputs, in: parent)
    }

    @concurrent
    private static func build(_ inputs: ProblemReport.Inputs, in parent: URL) async -> State {
        do {
            return .ready(try ProblemReport.build(inputs, in: parent))
        } catch {
            Log.diagnostics.error("Report not built", ["error": .error(LoggedError(error))])
            return .failed(ReportWording.buildFailed(error.localizedDescription))
        }
    }

    /// Opens a new email with the report attached; if Mail can't, reveals the report instead.
    func createEmail() {
        guard case .ready(let report) = state else { return }
        let items: [Any] = [ReportWording.emailBody, report.archive.url]
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items)
        else {
            Log.diagnostics.error("Email compose unavailable")
            notice = ReportWording.emailUnavailable
            showInFinder()
            return
        }
        service.recipients = [ProblemReport.destination]
        service.subject = ReportWording.emailSubject
        service.perform(withItems: items)
        close()
    }

    func showInFinder() {
        guard case .ready(let report) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([report.archive.url])
    }
}

struct ReportView: View {
    let model: ReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .preparing:
                ProgressView(ReportWording.preparing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let report):
                Text(ReportWording.intro)
                    .fixedSize(horizontal: false, vertical: true)
                ManifestList(manifest: report.manifest)
            case .failed(let message):
                Text(message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }

    private var buttons: some View {
        HStack {
            Button(isReady ? ReportWording.cancel : ReportWording.close, action: model.close)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(ReportWording.showInFinder, action: model.showInFinder)
                .disabled(!isReady)
            Button(ReportWording.createEmail, action: model.createEmail)
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady)
        }
    }

    private var isReady: Bool {
        if case .ready = model.state { true } else { false }
    }
}

private struct ManifestList: View {
    let manifest: ProblemReport.Manifest

    var body: some View {
        List {
            Section {
                ForEach(manifest.included, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.body.monospaced())
                        Text(item.reason).foregroundStyle(.secondary)
                    }
                }
            }
            if !manifest.notIncluded.isEmpty {
                Section(ReportWording.notIncludedHeading) {
                    ForEach(manifest.notIncluded, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
