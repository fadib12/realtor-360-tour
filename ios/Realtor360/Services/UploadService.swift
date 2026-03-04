import Foundation

class UploadService: ObservableObject {
    @Published var isUploading = false
    @Published var progress: Double = 0
    @Published var currentFile: Int = 0
    @Published var totalFiles: Int = 0
    @Published var error: Error?
    @Published var isComplete = false
    
    private let tourId: String
    
    init(tourId: String) {
        self.tourId = tourId
    }
    
    /// Upload all captured frames and trigger stitching
    @MainActor
    func uploadFrames(fileURLs: [URL], framesMeta: [FrameMeta]) async {
        isUploading = true
        progress = 0
        currentFile = 0
        totalFiles = fileURLs.count
        error = nil
        isComplete = false
        
        do {
            // Step 1: Get presigned upload URLs
            print("Getting upload URLs...")
            let uploadResponse = try await APIService.shared.getUploadUrls(
                tourId: tourId,
                count: fileURLs.count
            )
            
            guard uploadResponse.uploadUrls.count == fileURLs.count else {
                throw UploadError.urlCountMismatch
            }
            
            // Step 2: Upload each file
            print("Uploading \(fileURLs.count) files...")
            for (index, (fileURL, presignedURL)) in zip(fileURLs, uploadResponse.uploadUrls).enumerated() {
                currentFile = index + 1
                
                try await uploadFile(localURL: fileURL, presignedURL: presignedURL)
                
                progress = Double(index + 1) / Double(totalFiles)
                print("Uploaded file \(index + 1)/\(totalFiles)")
            }
            
            // Step 3: Notify server upload is complete
            print("Completing upload...")
            _ = try await APIService.shared.completeUpload(
                tourId: tourId,
                frameKeys: uploadResponse.frameKeys,
                framesMeta: framesMeta
            )
            
            isComplete = true
            print("Upload complete!")
            
        } catch {
            self.error = error
            print("Upload failed: \(error.localizedDescription)")
        }
        
        isUploading = false
    }
    
    private func uploadFile(localURL: URL, presignedURL: String) async throws {
        guard let url = URL(string: presignedURL) else {
            throw UploadError.invalidURL
        }
        
        let fileData = try Data(contentsOf: localURL)
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = fileData
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UploadError.uploadFailed(statusCode: httpResponse.statusCode)
        }
    }
}

enum UploadError: LocalizedError {
    case invalidURL
    case invalidResponse
    case uploadFailed(statusCode: Int)
    case urlCountMismatch
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid upload URL"
        case .invalidResponse:
            return "Invalid server response"
        case .uploadFailed(let statusCode):
            return "Upload failed (status: \(statusCode))"
        case .urlCountMismatch:
            return "Server returned wrong number of upload URLs"
        }
    }
}
