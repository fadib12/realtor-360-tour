import SwiftUI
import PhotosUI

/// Top-level coordinator view for the Capture tab.
/// Manages the flow: Home → Camera → Upload → Result.
struct CaptureTabView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject private var captureVM = CaptureViewModel()

    @State private var activeScreen: ActiveScreen = .home
    @State private var captureName = ""
    @State private var uploadSession: CaptureSession?
    @State private var uploadImageData: [Data] = []
    @State private var uploadHDRResults: [HDRBracketResult] = []
    @State private var completedSession: CaptureSession?

    enum ActiveScreen {
        case home, camera, upload, result
    }

    var body: some View {
        switch activeScreen {
        case .home:
            CaptureHomeView(
                name: $captureName,
                onBeginCapture: {
                    Task {
                        await captureVM.startCapture()
                        activeScreen = .camera
                    }
                },
                onImportPanorama: { data in
                    var session = CaptureSession(
                        name: captureName.isEmpty ? "Imported Panorama" : captureName,
                        captureType: .panorama360
                    )
                    // Persist imported image to disk so ResultView can find it
                    FileHelper.saveCapture(data, sessionId: session.id, step: 1)
                    session.localImagePaths = ["step_01.jpg"]
                    uploadSession = session
                    uploadImageData = [data]
                    activeScreen = .upload
                }
            )
            .transition(.opacity)

        case .camera:
            GuidedCaptureView(captureVM: captureVM) {
                // On complete — use the VM's sessionId so saved files match
                var session = CaptureSession(name: captureName, captureType: .multiPhoto16)
                session.id = captureVM.sessionId
                uploadSession = session
                uploadImageData = captureVM.capturedImageData
                uploadHDRResults = captureVM.capturedHDRData
                withAnimation { activeScreen = .upload }
            } onCancel: {
                captureVM.stopCapture()
                captureVM.reset()
                withAnimation { activeScreen = .home }
            }
            .transition(.move(edge: .trailing))

        case .upload:
            if let session = uploadSession {
                UploadProcessingView(
                    session: session,
                    imageData: uploadImageData,
                    hdrResults: uploadHDRResults,
                    onComplete: { completed in
                        completedSession = completed
                        sessionStore.save(completed)
                        withAnimation { activeScreen = .result }
                    },
                    onCancel: {
                        captureVM.reset()
                        captureName = ""
                        withAnimation { activeScreen = .home }
                    }
                )
                .transition(.move(edge: .trailing))
            }

        case .result:
            if let session = completedSession {
                CaptureResultView(session: session) {
                    // Done → go home
                    captureVM.reset()
                    captureName = ""
                    completedSession = nil
                    uploadSession = nil
                    uploadHDRResults = []
                    withAnimation { activeScreen = .home }
                }
                .transition(.move(edge: .trailing))
            }
        }
    }
}
