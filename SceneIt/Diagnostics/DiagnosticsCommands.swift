import SceneItCore
import SwiftUI

struct DiagnosticsCommands: Commands {
    let diagnostics: DiagnosticsController

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(ReportWording.reportMenuItem, action: diagnostics.showReportWindow)
        }
        #if DEBUG
            CommandMenu(ReportWording.debugMenu) {
                Button(ReportWording.crashNowMenuItem) {
                    fatalError("Crash Now chosen from the Debug menu")
                }
            }
        #endif
    }
}
