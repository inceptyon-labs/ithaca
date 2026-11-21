import SwiftUI

struct SignInView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.openURL) private var openURL
    @State private var linkPinCode: String?
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var pollingTask: Task<Void, Never>?
    @State private var authURL: URL?

    var body: some View {
        ZStack {
            Color.ithacaBackground.ignoresSafeArea()

            signInContent
        }
        #if !os(tvOS)
        .sheet(isPresented: authSheetPresented) {
            if let authURL {
                IthacaSafariView(url: authURL)
            }
        }
        #endif
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    @ViewBuilder
    private var signInContent: some View {
        #if os(tvOS)
        tvSignInContent
        #else
        iosSignInContent
        #endif
    }

    private var iosSignInContent: some View {
        VStack(spacing: 0) {
            Spacer()

            branding(iconSize: 80, titleFont: .largeTitle)

            Spacer()

            VStack(spacing: 24) {
                signInError

                if isSigningIn {
                    VStack(spacing: 12) {
                        Text("Complete sign-in in the Plex page that opened, or go to")
                            .foregroundStyle(Color.ithacaTextSecondary)
                            .font(.callout)

                        if let linkPinCode {
                            linkCodeContent(
                                code: linkPinCode,
                                titleFont: .headline,
                                codeFont: .system(.title, design: .monospaced, weight: .bold)
                            )
                        }
                    }
                }

                signInButton
                    .padding(.horizontal, 40)

                if isSigningIn {
                    cancelButton
                }
            }

            Spacer()
                .frame(height: 60)
        }
    }

    private var tvSignInContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                branding(
                    iconSize: 112,
                    titleFont: IthacaFont.pageTitleRounded(
                        ios: .system(size: 44, weight: .bold, design: .rounded)
                    )
                )

                VStack(spacing: 10) {
                    Text("Sign in with Plex")
                        .font(IthacaFont.sectionHeader(ios: .title2.weight(.semibold)))
                        .foregroundStyle(Color.ithacaTextPrimary)

                    Text("On another device, open plex.tv/link and enter the code shown below.")
                        .font(IthacaFont.pageSubtitle(ios: .title3))
                        .foregroundStyle(Color.ithacaTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 720)
                }

                signInError

                if let linkPinCode {
                    VStack(spacing: 12) {
                        Text("plex.tv/link")
                            .font(IthacaFont.rowTitle(ios: .title3.weight(.semibold)))
                            .foregroundStyle(Color.ithacaTextSecondary)

                        Text(linkPinCode)
                            .font(.system(size: 54, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .foregroundStyle(Color.ithacaTextPrimary)
                    }
                    .padding(.horizontal, 54)
                    .padding(.vertical, 28)
                    .background(Color.ithacaSurface, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                }

                signInButton
                    .frame(maxWidth: 520)

                if isSigningIn {
                    cancelButton
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    private func branding(iconSize: CGFloat, titleFont: Font) -> some View {
        VStack(spacing: 16) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)

            VStack(spacing: 6) {
                Text("Ithaca")
                    .font(titleFont)
                    .foregroundStyle(Color.ithacaTextPrimary)
                Text("The Plex App we Deserve.")
                    .font(IthacaFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.ithacaTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var signInError: some View {
        if let error {
            Text(error)
                .foregroundStyle(.red)
                .font(IthacaFont.body(ios: .callout))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack(spacing: 8) {
                if isSigningIn {
                    ProgressView()
                        #if !os(tvOS)
                        .tint(Color.ithacaPrimaryActionLabel)
                        #endif
                }
                Text(isSigningIn ? "Waiting for approval…" : "Sign in with Plex")
            }
            .font(IthacaFont.buttonLabel(ios: .headline))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            #if !os(tvOS)
            .foregroundStyle(Color.ithacaPrimaryActionLabel)
            #endif
        }
        .disabled(isSigningIn)
        .detailHeroNativePrimaryButtonStyle()
    }

    private var cancelButton: some View {
        Button("Cancel") {
            cancelSignIn()
        }
        .ithacaFont(tvOnly: IthacaFont.TV.buttonLabel)
        .foregroundStyle(Color.ithacaTextSecondary)
        .ithacaSuppressTVOSButtonChrome()
        .ithacaTVOSFocusEffectShape(Capsule())
    }

    private func linkCodeContent(code: String, titleFont: Font, codeFont: Font) -> some View {
        VStack(spacing: 12) {
            Text("plex.tv/link")
                .font(titleFont)
                .foregroundStyle(Color.ithacaTextPrimary)
            Text("and enter this code:")
                .foregroundStyle(Color.ithacaTextSecondary)
                .font(.callout)
            Text(code)
                .font(codeFont)
                .tracking(4)
                .foregroundStyle(Color.ithacaTextPrimary)
        }
    }

    private func signIn() async {
        isSigningIn = true
        error = nil
        linkPinCode = nil

        do {
            #if os(tvOS)
            let linkPin = try await plexService.generatePin()
            linkPinCode = linkPin.code
            startPolling(primaryPinID: linkPin.id, expiresAt: Self.expiryDate(of: linkPin))
            #else
            // Plex uses a longer-lived "strong" PIN for browser approval, but
            // plex.tv/link expects the short code flow, so we keep both active.
            let browserPin = try await plexService.generatePin(strong: true)
            let linkPin = try? await plexService.generatePin()
            linkPinCode = linkPin?.code

            guard let url = plexService.authURL(for: browserPin) else {
                throw PlexServiceError.invalidURL
            }

            startPolling(
                primaryPinID: browserPin.id,
                fallbackPinID: linkPin?.id,
                expiresAt: Self.expiryDate(of: browserPin)
            )
            openAuthURL(url)
            #endif
        } catch {
            self.error = error.localizedDescription
            isSigningIn = false
        }
    }

    /// Plex link codes stay valid until the PIN's own expiry (about 15 minutes),
    /// so polling runs that long rather than for a fixed couple of minutes.
    private static func expiryDate(of pin: PlexPin) -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: pin.expiresAt) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: pin.expiresAt) ?? Date().addingTimeInterval(15 * 60)
    }

    private func startPolling(primaryPinID: Int, fallbackPinID: Int? = nil, expiresAt: Date) {
        pollingTask?.cancel()
        pollingTask = Task {
            let fallbackActivationAttempt = 15
            var attempt = 0

            while Date() < expiresAt {
                attempt += 1
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                if let token = try? await plexService.checkPin(primaryPinID) {
                    plexService.setAuthToken(token)
                    isSigningIn = false
                    linkPinCode = nil
                    authURL = nil
                    return
                }

                if attempt >= fallbackActivationAttempt,
                   let fallbackPinID,
                   let token = try? await plexService.checkPin(fallbackPinID) {
                        plexService.setAuthToken(token)
                        isSigningIn = false
                        linkPinCode = nil
                        authURL = nil
                        return
                }
            }

            #if os(tvOS)
            // The code expired unused. Show a fresh one instead of a dead end.
            if let linkPin = try? await plexService.generatePin() {
                linkPinCode = linkPin.code
                startPolling(primaryPinID: linkPin.id, expiresAt: Self.expiryDate(of: linkPin))
                return
            }
            #endif

            // The PIN expired without approval — a genuine timeout.
            // Cancellation (Cancel button, closing the view, restarting sign-in)
            // returns early above, so aborting never surfaces this message.
            guard !Task.isCancelled else { return }
            isSigningIn = false
            linkPinCode = nil
            authURL = nil
            error = "Sign-in timed out. Please try again."
        }
    }

    private func cancelSignIn() {
        pollingTask?.cancel()
        isSigningIn = false
        linkPinCode = nil
        authURL = nil
    }

    #if !os(tvOS)
    private var authSheetPresented: Binding<Bool> {
        Binding(
            get: { authURL != nil },
            set: {
                guard !$0 else { return }
                authURL = nil
            }
        )
    }

    /// Opens the Plex approval page for the browser PIN.
    ///
    /// On iPhone/iPad this presents the in-app `SFSafariViewController` sheet.
    /// For an iOS app running on macOS ("Designed for iPad") that sheet is
    /// unreliable — the system hands the URL to the default browser and
    /// dismisses the sheet immediately — so we open the external browser
    /// directly there instead. Either path leaves polling running and the
    /// `plex.tv/link` code on screen as the fallback.
    private func openAuthURL(_ url: URL) {
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
            openURL(url)
        } else {
            authURL = url
        }
    }
    #endif
}
