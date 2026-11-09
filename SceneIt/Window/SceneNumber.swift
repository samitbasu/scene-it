import SceneItCore
import SwiftUI

/// A scene's number in a circle, or **B** for the Boneyard: the Search sheet's result groups and
/// the Scenes sheet's cards.
struct SceneNumber: View {
    let placement: ScenePlacement

    var body: some View {
        Text(SearchWording.sceneNumber(placement))
            .font(.system(size: 11, weight: .semibold))
            .frame(width: WindowMetrics.Search.numberSize, height: WindowMetrics.Search.numberSize)
            .background(Circle().fill(Color.white))
            .overlay(Circle().strokeBorder(WindowMetrics.Search.line, lineWidth: 1.5))
    }
}
