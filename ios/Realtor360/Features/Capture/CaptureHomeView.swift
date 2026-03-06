import SwiftUI
import PhotosUI

struct CaptureHomeView: View {
    @Binding var name: String
    let onBeginCapture: () -> Void
    let onImportPanorama: (Data) -> Void

    @State private var photosPickerItem: PhotosPickerItem?

    private var nameIsEmpty: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                // Title
                Text("Capture")
                    .font(.system(size: 34, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                // Mode badge: make backend mode obvious while testing.
                HStack {
                    Text(AppConfig.isMockMode ? "Mock Mode (Offline)" : "Live Backend")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppConfig.isMockMode ? .orange : .green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            (AppConfig.isMockMode ? Color.orange : Color.green).opacity(0.14),
                            in: Capsule()
                        )
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

                // Name field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    TextField("Tokyo Tower 🗼", text: $name)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)

                // Begin capture
                Button(action: onBeginCapture) {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.fill")
                        Text("Begin capture")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(nameIsEmpty ? Color.gray.opacity(0.4) : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(nameIsEmpty)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                // Divider
                HStack(spacing: 12) {
                    Rectangle().fill(Color(.systemGray4)).frame(height: 1)
                    Text("or").font(.subheadline).foregroundStyle(.secondary)
                    Rectangle().fill(Color(.systemGray4)).frame(height: 1)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                // Import 360°
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("Import 360° photo")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(.systemGray6))
                    .foregroundColor(.blue)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationBarHidden(true)
            .onChange(of: photosPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        onImportPanorama(data)
                    }
                }
            }
        }
    }
}
