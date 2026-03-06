import SwiftUI

struct UploadProcessingView: View {
    let session: CaptureSession
    let imageData: [Data]
    let hdrResults: [HDRBracketResult]
    let onComplete: (CaptureSession) -> Void
    let onCancel: () -> Void

    @StateObject private var vm: UploadViewModel
    @State private var showCancelAlert = false

    init(session: CaptureSession, imageData: [Data],
         hdrResults: [HDRBracketResult] = [],
         onComplete: @escaping (CaptureSession) -> Void,
         onCancel: @escaping () -> Void) {
        self.session = session
        self.imageData = imageData
        self.hdrResults = hdrResults
        self.onComplete = onComplete
        self.onCancel = onCancel
        _vm = StateObject(wrappedValue: UploadViewModel(
            session: session, imageData: imageData, hdrResults: hdrResults
        ))
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 120, height: 120)

                if vm.status == .complete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else if vm.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(statusColor)
                }
            }
            .animation(.spring(response: 0.4), value: vm.status)

            // Status text
            VStack(spacing: 8) {
                Text(vm.statusText)
                    .font(.title3.weight(.semibold))

                if AppConfig.isMockMode {
                    Text("Local on-device processing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = vm.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            // Progress bars
            VStack(spacing: 16) {
                if vm.status == .uploading || vm.uploadProgress > 0 {
                    progressRow(label: "Upload", value: vm.uploadProgress)
                }
                if vm.status == .processing || vm.processingProgress > 0 {
                    progressRow(label: "Processing", value: vm.processingProgress)
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            // Actions
            VStack(spacing: 12) {
                if vm.status == .complete {
                    Button {
                        if let completed = vm.completedSession {
                            onComplete(completed)
                        }
                    } label: {
                        Text("View Result")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)
                } else if vm.status == .failed {
                    Button {
                        Task { await vm.retry() }
                    } label: {
                        Text("Retry")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)
                }

                if vm.status != .complete {
                    Button {
                        showCancelAlert = true
                    } label: {
                        Text("Cancel")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .task { await vm.start() }
        .alert("Cancel Upload?", isPresented: $showCancelAlert) {
            Button("Cancel Upload", role: .destructive) {
                vm.cancel()
                onCancel()
            }
            Button("Continue", role: .cancel) { }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch vm.status {
        case .complete: return .green
        case .failed:   return .red
        default:        return .blue
        }
    }

    private func progressRow(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5)).frame(height: 6)
                    Capsule().fill(Color.blue).frame(width: geo.size.width * value, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: value)
                }
            }
            .frame(height: 6)
        }
    }
}
