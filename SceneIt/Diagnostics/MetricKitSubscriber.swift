import MetricKit
import SceneItCore

/// Saves the crash and hang diagnostics MetricKit delivers (on a later launch) as JSON.
/// MetricKit calls this on a background queue.
nonisolated final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private let archive: PayloadArchive

    init(archive: PayloadArchive) {
        self.archive = archive
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            archive.save(payload.jsonRepresentation())
        }
    }
}
