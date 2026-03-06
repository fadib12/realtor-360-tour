import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 1 // default to Capture

    var body: some View {
        TabView(selection: $selectedTab) {
            ExploreView()
                .tabItem {
                    Label("Explore", systemImage: "safari")
                }
                .tag(0)

            CaptureTabView()
                .tabItem {
                    Label("Capture", systemImage: "camera.fill")
                }
                .tag(1)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
                .tag(2)
        }
        .tint(.blue)
    }
}
