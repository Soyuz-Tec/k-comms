import SwiftUI
import LiveKit

@main struct KCommsApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        LiveKitSDK.disableLogging()
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await model.sceneActive(true) } }
                    else if phase == .background { Task { await model.sceneActive(false) } }
                }
        }
    }
}
