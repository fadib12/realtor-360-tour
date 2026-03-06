import SwiftUI
import WebKit

/// Displays the World Labs navigable 3D environment inside a WKWebView.
struct WorldViewer: View {
    let worldUrl: URL?
    @Environment(\.dismiss) private var dismiss

    init(worldUrl: URL? = nil) {
        self.worldUrl = worldUrl
    }

    /// Convenience: load from a CaptureSession.
    init(session: CaptureSession) {
        if let urlString = session.worldUrl, let url = URL(string: urlString) {
            self.worldUrl = url
        } else {
            self.worldUrl = nil
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let url = worldUrl {
                WorldWebView(url: url)
                    .ignoresSafeArea()
            } else {
                placeholderView
            }

            // Close button
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(.top, 12)
            .padding(.leading, 16)
        }
    }

    private var placeholderView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("3D world not available yet")
                    .foregroundStyle(.secondary)
                Text("The world is being generated.\nThis may take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - WKWebView wrapper

private struct WorldWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false  // 3D world handles its own gestures
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
