import SwiftUI
import SwiftTwitchMiner

/// Authentication view for device-code OAuth flow.
/// Displays the user code and verification URL with copy functionality.
struct AuthView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isWaiting = false
    @State private var showCopiedCode = false
    @State private var showCopiedURL = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "tv.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.purple)
                
                Text("Connect to Twitch")
                    .font(.title)
                    .fontWeight(.semibold)
                
                Text("Sign in to your Twitch account to start earning drops")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
            
            if let authInfo = appModel.authInfo {
                // Device code display
                VStack(spacing: 16) {
                    // User Code
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your Code", systemImage: "number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 12) {
                            Text(authInfo.userCode)
                                .font(.system(size: 32, weight: .bold, design: .monospaced))
                                .tracking(4)
                            
                            Button {
                                copyToClipboard(authInfo.userCode, type: .code)
                            } label: {
                                Image(systemName: showCopiedCode ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .glassPanel(cornerRadius: 18)
                    }
                    
                    // Verification URL
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Verification URL", systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 12) {
                            Text(authInfo.verificationURL.absoluteString)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            Button {
                                copyToClipboard(authInfo.verificationURL.absoluteString, type: .url)
                            } label: {
                                Image(systemName: showCopiedURL ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .glassPanel(cornerRadius: 18)
                    }
                    
                    // Open URL Button
                    Button {
                        NSWorkspace.shared.open(authInfo.verificationURL)
                    } label: {
                        Label("Open Twitch in Browser", systemImage: "safari")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                    
                    // Waiting indicator
                    if isWaiting {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Waiting for authorization...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 32)
            } else {
                // Start auth button
                VStack(spacing: 16) {
                    Button {
                        startAuthentication()
                    } label: {
                        Label("Connect to Twitch", systemImage: "person.badge.key")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isWaiting)
                    
                    if isWaiting {
                        ProgressView()
                            .padding(.top, 8)
                    }
                }
            }
            
            Spacer()
            
            // Footer
            Text("You'll be redirected to Twitch to authorize this app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: 500)
        .padding(24)
        .glassContentSurface(cornerRadius: 32)
    }
    
    private func startAuthentication() {
        isWaiting = true
        Task {
            do {
                try await appModel.startAuthentication()
                // After getting auth info, wait for user to complete auth
                await appModel.waitForAuthentication()
            } catch {
                appModel.lastError = error as? TwitchMinerError ?? .unknown(error.localizedDescription)
            }
            isWaiting = false
        }
    }
    
    private enum CopyType { case code, url }
    
    private func copyToClipboard(_ string: String, type: CopyType) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        
        withAnimation(.easeInOut(duration: 0.2)) {
            switch type {
            case .code:
                showCopiedCode = true
            case .url:
                showCopiedURL = true
            }
        }
        
        // Reset after delay
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    switch type {
                    case .code:
                        showCopiedCode = false
                    case .url:
                        showCopiedURL = false
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AuthView()
        .environment(AppModel(clientId: "preview"))
}
