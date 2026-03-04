import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if appState.showCapture, let tourId = appState.currentTourId {
                CaptureStartView(tourId: tourId)
            } else {
                WelcomeView()
            }
        }
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Logo
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
            
            VStack(spacing: 8) {
                Text("Realtor 360")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("360° Virtual Tour Capture")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Instructions
            VStack(spacing: 16) {
                InstructionRow(
                    icon: "qrcode.viewfinder",
                    text: "Open the Realtor 360 website and create a tour"
                )
                
                InstructionRow(
                    icon: "camera.fill",
                    text: "Scan the QR code to start capturing"
                )
                
                InstructionRow(
                    icon: "arrow.up.circle.fill",
                    text: "Photos will upload automatically"
                )
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            Text("Scan a tour QR code to get started")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.bottom, 32)
        }
    }
}

struct InstructionRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 32)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
