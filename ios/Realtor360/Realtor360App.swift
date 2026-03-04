import SwiftUI

@main
struct Realtor360App: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    handleUniversalLink(url)
                }
        }
    }
    
    private func handleUniversalLink(_ url: URL) {
        // Handle capture URL: realtor360://capture/{tourId}
        // or https://realtor360.app/capture/{tourId}
        
        let pathComponents = url.pathComponents
        
        if let captureIndex = pathComponents.firstIndex(of: "capture"),
           captureIndex + 1 < pathComponents.count {
            let tourId = pathComponents[captureIndex + 1]
            appState.openTour(tourId: tourId)
        }
    }
}

// Global app state
class AppState: ObservableObject {
    @Published var currentTourId: String?
    @Published var showCapture: Bool = false
    
    func openTour(tourId: String) {
        currentTourId = tourId
        showCapture = true
    }
    
    func closeTour() {
        currentTourId = nil
        showCapture = false
    }
}
