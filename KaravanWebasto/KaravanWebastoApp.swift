import SwiftUI

@main
struct KaravanWebastoApp: App {
    @StateObject private var controller = HeaterController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
        }
    }
}
