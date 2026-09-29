import SwiftData
import SwiftUI

@main
struct SeeingCalendarApp: App {
    private let container: ModelContainer

    init() {
        container = AppDataStack.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
