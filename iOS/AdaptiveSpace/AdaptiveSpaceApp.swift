import SwiftUI

@main
struct AdaptiveSpaceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            FlowView(model: model)
        }
    }
}
