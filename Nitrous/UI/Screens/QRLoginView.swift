import SwiftUI
import CoreImage.CIFilterBuiltins

/// Sign in by scanning a QR code with the official Discord app — the same
/// remote-auth flow Discord's desktop client uses. No token pasting.
struct QRLoginView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = RemoteAuthClient()
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    switch auth.phase {
                    case .connecting:
                        placeholder { ProgressView().controlSize(.large) }
                        Text("Preparing a secure code…")
                            .font(.subheadline).foregroundStyle(.secondary)

                    case .awaitingScan(let url):
                        qr(for: url)
                        VStack(spacing: 6) {
                            Text("Scan with the Discord app")
                                .font(.headline)
                            Text("Open Discord on your phone, tap your avatar → **Scan QR Code**, then point it at this code.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                    case .awaitingApproval(let user):
                        VStack(spacing: 14) {
                            AvatarView(url: user.avatarURL, name: user.username,
                                       size: 88, seed: user.id)
                            Text(user.username).font(.title2.bold())
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Confirm on your phone to finish")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 30)

                    case .success:
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 68)).foregroundStyle(.green)
                            Text("Signed in").font(.title2.bold())
                        }
                        .padding(.top, 30)

                    case .failed(let message):
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 54)).foregroundStyle(.orange)
                            Text("Sign-in failed").font(.headline)
                            Text(message).font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Start Over") { auth.start() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 30)
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    if busy { ProgressView() }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .themedBackground()
            .navigationTitle("Scan to Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { auth.cancel(); dismiss() }
                }
            }
        }
        .onAppear {
            auth.onToken = { token in
                busy = true
                Task {
                    do { try await model.addAccount(token: token); dismiss() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
            auth.start()
        }
        .onDisappear { auth.cancel() }
    }

    // MARK: QR rendering

    private func qr(for string: String) -> some View {
        placeholder {
            if let image = Self.qrImage(from: string) {
                Image(uiImage: image)
                    .interpolation(.none)      // keep the modules crisp
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            } else {
                Text("Couldn't render the code").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            content()
        }
        .frame(width: 260, height: 260)
    }

    /// Generates a QR code at a resolution high enough to scan off-screen.
    static func qrImage(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
