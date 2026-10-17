import SwiftUI

@main
struct MTunlApp: App {
    @StateObject private var model = TunnelModel()

    var body: some Scene {
        MenuBarExtra("MTunl", systemImage: "arrow.left.arrow.right") {
            TunnelMenuView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
