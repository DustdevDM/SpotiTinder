import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @Environment(SpotifyAuth.self) private var auth
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("SpotiTinder")
                .font(.largeTitle.bold())
            Text("Swipe through your playlist.\nKeep what you love, clear out the rest.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await logIn() }
            } label: {
                Label("Log in with Spotify", systemImage: "music.note")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        }
        .padding()
    }

    private func logIn() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        let request = auth.makeAuthorizationRequest()
        do {
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: request.url,
                callback: .customScheme(Config.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            try await auth.completeLogin(callbackURL: callbackURL, request: request)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User closed the login sheet.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
