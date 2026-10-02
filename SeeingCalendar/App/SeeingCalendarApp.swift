import SwiftData
import SwiftUI

@main
struct SeeingCalendarApp: App {
    private let container: ModelContainer

    init() {
        container = AppDataStack.makeContainer()
        AppDataStack.migrateSubscriptionScopes(in: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
