import SwiftUI

@MainActor
class UploadViewModel: ObservableObject {

    // MARK: - Published state

    @Published var status: UploadStatus = .preparing
    @Published var uploadProgress: Double = 0
    @Published var processingProgress: Double = 0
    @Published var statusText = "Preparing…"
    @Published var completedSession: CaptureSession?
    @Published var error: String?

    enum UploadStatus: Equatable {
        case preparing, uploading, processing, complete, failed
    }

    // MARK: - Private

    private let apiClient: APIClientProtocol
    private var session: CaptureSession
    private let imageData: [Data]
    /// Optional HDR bracket results for EXR stitching.
    private let hdrResults: [HDRBracketResult]
    private var cancelled = false
    private var remoteSessionId: String = ""

    init(session: CaptureSession,
         imageData: [Data],
         hdrResults: [HDRBracketResult] = [],
         apiClient: APIClientProtocol = AppConfig.apiClient) {
        self.session = session
        self.imageData = imageData
        self.hdrResults = hdrResults
        self.apiClient = apiClient
    }

    // MARK: - Upload flow

    func start() async {
        cancelled = false
        if AppConfig.isMockMode {
            await processLocally()
            return
        }

        status = .uploading
        statusText = "Creating session…"

        do {
            let response = try await apiClient.createSession(
                name: session.name,
                captureType: session.captureType,
                photoCount: imageData.count
            )
            remoteSessionId = response.id  // keep session.id for local file paths

            // Upload each photo
            if session.captureType == .multiPhoto16, let urls = response.uploadUrls {
                for (i, url) in urls.enumerated() {
                    guard i < imageData.count, !cancelled else { return }
                    statusText = "Uploading photo \(i + 1) of \(imageData.count)…"
                    try await apiClient.uploadPhoto(to: url, data: imageData[i])
                    uploadProgress = Double(i + 1) / Double(imageData.count)
                }
            } else if let url = response.panoramaUploadUrl, let data = imageData.first {
                statusText = "Uploading panorama…"
                try await apiClient.uploadPhoto(to: url, data: data)
                uploadProgress = 1.0
            }

            guard !cancelled else { return }
            await startProcessing()

        } catch {
            if !cancelled {
                self.error = error.localizedDescription
                status = .failed
            }
        }
    }

    // MARK: - Local-only flow (no backend)

    private func processLocally() async {
        status = .processing
        statusText = "Stitching on device…"
        processingProgress = 0.1

        let localImages = self.imageData
        let localHDR = self.hdrResults
        let localSessionId = self.session.id

        let stitched: Data? = await Task.detached { () -> Data? in
            if !localHDR.isEmpty {
                return PanoramaStitcher.stitchHDR(
                    hdrResults: localHDR,
                    positions: SphereGrid.targets,
                    sessionId: localSessionId
                )
            }

            if localImages.count > 1 {
                return PanoramaStitcher.stitch(
                    images: localImages,
                    sessionId: localSessionId
                )
            }

            if let only = localImages.first {
                FileHelper.savePanorama(only, sessionId: localSessionId)
                return only
            }

            return nil
        }.value

        guard !cancelled else { return }

        if stitched == nil {
            error = "Local stitching failed. Try recapturing with more overlap and steadier motion."
            status = .failed
            return
        }

        processingProgress = 1.0
        session.status = .complete
        session.generatedAt = Date()
        session.panoramaURL = nil
        session.previewURL = nil
        session.worldUrl = nil
        session.thumbnailUrl = nil
        session.splatsUrls = nil
        session.colliderMeshUrl = nil
        completedSession = session
        status = .complete
        statusText = "Panorama ready"
    }

    // MARK: - Processing + polling

    private func startProcessing() async {
        status = .processing
        statusText = "Stitching panorama…"

        // Stitch photos into equirectangular panorama on a background thread.
        // When HDR bracket data is available, stitch as 32-bit EXR.
        // Otherwise fall back to JPEG compositing.
        let localImages = self.imageData
        let localHDR = self.hdrResults
        let localSessionId = self.session.id
        let stitchTask = Task.detached { () -> Data? in
            if !localHDR.isEmpty {
                // HDR path → 32-bit EXR equirectangular panorama
                return PanoramaStitcher.stitchHDR(
                    hdrResults: localHDR,
                    positions: SphereGrid.targets,
                    sessionId: localSessionId
                )
            } else {
                // LDR fallback → JPEG equirectangular panorama
                return PanoramaStitcher.stitch(
                    images: localImages,
                    sessionId: localSessionId
                )
            }
        }

        do {
            _ = try await apiClient.startProcessing(sessionId: remoteSessionId)
            statusText = "Processing your capture…"

            while status == .processing && !cancelled {
                try await Task.sleep(for: .seconds(2))
                let result = try await apiClient.pollStatus(sessionId: remoteSessionId)
                processingProgress = result.progress ?? 0

                switch result.status {
                case "complete":
                    // Wait for local stitch to finish (usually already done)
                    let _ = await stitchTask.value
                    session.status = .complete
                    session.panoramaURL = result.panoramaUrl
                    session.previewURL  = result.previewUrl
                    session.worldUrl       = result.worldUrl
                    session.thumbnailUrl   = result.thumbnailUrl
                    session.colliderMeshUrl = result.colliderMeshUrl
                    if let s = result.splats {
                        session.splatsUrls = SplatsUrls(low: s.low, medium: s.medium, full: s.fullRes)
                    }
                    if let s = result.generatedAt {
                        session.generatedAt = ISO8601DateFormatter().date(from: s)
                    }
                    completedSession = session
                    status = .complete
                    statusText = "Complete!"

                case "failed":
                    error = result.errorMessage ?? "Server processing failed"
                    status = .failed

                default:
                    statusText = "Processing… \(Int(processingProgress * 100))%"
                }
            }
        } catch {
            if !cancelled {
                self.error = error.localizedDescription
                status = .failed
            }
        }
    }

    // MARK: - Actions

    func retry() async {
        error = nil
        uploadProgress = 0
        processingProgress = 0
        await start()
    }

    func cancel() {
        cancelled = true
        status = .failed
        statusText = "Cancelled"
    }
}
