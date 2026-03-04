import SwiftUI

struct CaptureStartView: View {
    let tourId: String
    
    @EnvironmentObject var appState: AppState
    @State private var tour: TourResponse?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showCapture = false
    
    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .padding()
                    Text("Loading tour...")
                        .foregroundColor(.secondary)
                } else if let error = error {
                    ErrorView(message: error) {
                        Task { await loadTour() }
                    }
                } else if let tour = tour {
                    TourReadyView(tour: tour, showCapture: $showCapture)
                }
            }
            .navigationTitle("Capture Tour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        appState.closeTour()
                    }
                }
            }
            .fullScreenCover(isPresented: $showCapture) {
                GuidedCaptureView(tourId: tourId, tourName: tour?.name ?? "Tour")
            }
        }
        .task {
            await loadTour()
        }
    }
    
    private func loadTour() async {
        isLoading = true
        error = nil
        
        do {
            tour = try await APIService.shared.getTour(tourId: tourId)
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

struct TourReadyView: View {
    let tour: TourResponse
    @Binding var showCapture: Bool
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Tour info
            VStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text(tour.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                
                if let address = tour.address, !address.isEmpty {
                    HStack {
                        Image(systemName: "mappin")
                            .foregroundColor(.secondary)
                        Text(address)
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Instructions
            VStack(alignment: .leading, spacing: 16) {
                Text("Capture Instructions")
                    .font(.headline)
                
                InstructionItem(number: 1, text: "Stand in the center of the room")
                InstructionItem(number: 2, text: "Follow the target dot on screen")
                InstructionItem(number: 3, text: "Hold steady when aligned (auto-captures)")
                InstructionItem(number: 4, text: "Photos upload automatically when done")
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .padding(.horizontal)
            
            Spacer()
            
            // Start button
            Button {
                showCapture = true
            } label: {
                HStack {
                    Image(systemName: "camera.fill")
                    Text("Start Capture")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .cornerRadius(14)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
}

struct InstructionItem: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.blue)
                .clipShape(Circle())
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
            Text("Error")
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Retry") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    CaptureStartView(tourId: "test-tour-id")
        .environmentObject(AppState())
}
