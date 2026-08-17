import SwiftUI

@main
struct AdaptiveSpaceApp: App {
    @State private var model = AppModel(commandRouter: OnDeviceNeedleRouter())

    var body: some Scene {
        WindowGroup {
            FlowView(model: model)
        }
    }
}
