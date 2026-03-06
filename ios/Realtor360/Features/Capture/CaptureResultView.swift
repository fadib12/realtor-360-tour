import SwiftUI

struct CaptureResultView: View {
    let session: CaptureSession
    let onDone: () -> Void

    @State private var showPanorama = false
    @State private var showWorld = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // MARK: - Custom top bar (back + title)
                HStack {
                    Button { onDone() } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                            .background(Color(.systemGray5), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Session name
                Text(session.name)
                    .font(.system(size: 28, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // MARK: - Hero preview
                heroPreview
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // MARK: - Status row
                HStack {
                    Label("Complete", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.12), in: Capsule())

                    Spacer()

                    Text(session.timeAgoText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                // MARK: - Unlock your photo card
                unlockCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // MARK: - 3D World card
                worldCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                // MARK: - Action rows
                VStack(spacing: 1) {
                    actionRow(icon: "eye.fill", title: "Preview", subtitle: "View 360° panorama") {
                        showPanorama = true
                    }

                    actionRow(icon: "square.and.arrow.up", title: "Share", subtitle: "Share with others", isPro: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                // MARK: - Advanced section
                Text("Advanced")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                VStack(spacing: 1) {
                    actionRow(icon: "arrow.down.circle.fill", title: "Download", subtitle: "Save to Photos", isPro: true)

                    actionRow(icon: "map.fill", title: "Publish to Google Street View", subtitle: "Make it public on Maps", isPro: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showPanorama) {
            PanoramaViewer(session: session)
        }
        .fullScreenCover(isPresented: $showWorld) {
            WorldViewer(session: session)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var heroPreview: some View {
        if let img = FileHelper.firstCaptureImage(sessionId: session.id) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(.systemGray5)
                Image(systemName: "panorama")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unlockCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 56, height: 56)
                Image(systemName: "lock.open.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Unlock your photo")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("Access high resolution without watermark")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    private var worldCard: some View {
        Button { showWorld = true } label: {
            HStack(spacing: 14) {
                // Thumbnail
                if let img = FileHelper.firstCaptureImage(sessionId: session.id) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 56, height: 56)
                        Image(systemName: "cube.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("3D World")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Explore a 3D world generated from your photo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    if let date = session.generatedAt {
                        Text("Generated \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(.systemGray6))
            .cornerRadius(16)
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String,
                           isPro: Bool = false, action: (() -> Void)? = nil) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(isPro ? .secondary : .blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                        if isPro {
                            Text("PRO")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.systemGray6))
        }
        .disabled(isPro)
        .foregroundColor(.primary)
    }
}
