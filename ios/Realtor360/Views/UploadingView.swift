import SwiftUI

struct UploadingView: View {
    let tourId: String
    @ObservedObject var captureController: GuidedCaptureController
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var uploadService: UploadService
    
    init(tourId: String, captureController: GuidedCaptureController) {
        self.tourId = tourId
        self.captureController = captureController
        _uploadService = StateObject(wrappedValue: UploadService(tourId: tourId))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                
                // Status icon
                statusIcon
                
                // Status text
                statusText
                
                // Progress bar (while uploading)
                if uploadService.isUploading {
                    progressView
                }
                
                Spacer()
                
                // Actions
                actionButtons
            }
            .padding()
            .navigationTitle("Upload Tour")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if uploadService.isComplete || uploadService.error != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            cleanup()
                            appState.closeTour()
                        }
                    }
                }
            }
        }
        .task {
            await startUpload()
        }
    }
    
    // MARK: - Views
    
    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackgroundColor)
                .frame(width: 120, height: 120)
            
            if uploadService.isUploading {
                ProgressView()
                    .scaleEffect(2)
                    .tint(.blue)
            } else if uploadService.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.green)
            } else if uploadService.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
        }
    }
    
    @ViewBuilder
    private var statusText: some View {
        VStack(spacing: 8) {
            Text(statusTitle)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    @ViewBuilder
    private var progressView: some View {
        VStack(spacing: 8) {
            ProgressView(value: uploadService.progress)
                .progressViewStyle(LinearProgressViewStyle())
                .padding(.horizontal, 40)
            
            Text("Uploading \(uploadService.currentFile) of \(uploadService.totalFiles)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if uploadService.isComplete {
                Button {
                    openWebsite()
                } label: {
                    HStack {
                        Image(systemName: "safari")
                        Text("Open Tour on Website")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(14)
                }
                
                Button {
                    cleanup()
                    appState.closeTour()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(14)
                }
            } else if uploadService.error != nil {
                Button {
                    Task { await startUpload() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry Upload")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(14)
                }
            }
        }
        .padding(.bottom, 32)
    }
    
    // MARK: - Computed Properties
    
    private var iconBackgroundColor: Color {
        if uploadService.isComplete {
            return Color.green.opacity(0.1)
        } else if uploadService.error != nil {
            return Color.orange.opacity(0.1)
        }
        return Color.blue.opacity(0.1)
    }
    
    private var statusTitle: String {
        if uploadService.isComplete {
            return "Upload Complete!"
        } else if let error = uploadService.error {
            return "Upload Failed"
        } else if uploadService.isUploading {
            return "Uploading..."
        }
        return "Preparing Upload"
    }
    
    private var statusSubtitle: String {
        if uploadService.isComplete {
            return "Your panorama is being processed.\nThis usually takes 1-2 minutes."
        } else if let error = uploadService.error {
            return error.localizedDescription
        } else if uploadService.isUploading {
            return "Please keep the app open"
        }
        return "Getting ready to upload your photos"
    }
    
    // MARK: - Actions
    
    private func startUpload() async {
        let fileURLs = captureController.getCapturedFileURLs()
        let framesMeta = captureController.getFramesMeta()
        
        await uploadService.uploadFrames(
            fileURLs: fileURLs,
            framesMeta: framesMeta
        )
    }
    
    private func openWebsite() {
        // Open the tour URL in browser
        let baseURL = "http://localhost:3000"  // Configure for production
        if let url = URL(string: "\(baseURL)/tours/\(tourId)") {
            UIApplication.shared.open(url)
        }
    }
    
    private func cleanup() {
        captureController.cleanupFrames()
    }
}

#Preview {
    let camera = CameraService()
    let motion = MotionService()
    let controller = GuidedCaptureController(cameraService: camera, motionService: motion)
    
    return UploadingView(tourId: "test", captureController: controller)
        .environmentObject(AppState())
}
