import SwiftUI

struct ExploreView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @State private var selectedSession: CaptureSession?

    var completedSessions: [CaptureSession] {
        sessionStore.sessions.filter { $0.status == .complete }
    }

    var body: some View {
        NavigationStack {
            Group {
                if completedSessions.isEmpty {
                    emptyState
                } else {
                    List(completedSessions) { session in
                        Button {
                            selectedSession = session
                        } label: {
                            sessionRow(session)
                        }
                        .foregroundColor(.primary)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Explore")
            .fullScreenCover(item: $selectedSession) { session in
                CaptureResultView(session: session) {
                    selectedSession = nil
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No captures yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Complete a capture to see it here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: CaptureSession) -> some View {
        HStack(spacing: 14) {
            // Thumbnail
            if let img = FileHelper.firstCaptureImage(sessionId: session.id) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "panorama")
                            .foregroundStyle(.secondary)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.subheadline.weight(.medium))
                Text(session.timeAgoText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("Complete", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
        .padding(.vertical, 4)
    }
}
