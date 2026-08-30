import SwiftUI

/// A clean, Apple-style sign-in screen: adaptive light/dark, native form
/// fields, MFA sheet, token fallback, and (debug) a demo mode.
struct LoginView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var mfaTicket: String?
    @State private var mfaCode = ""
    @State private var showToken = false
    @State private var showQR = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Palette.accent.gradient)
                            .padding(.top, 40)
                        Text("Nitrous").font(.largeTitle.bold())
                        Text("Sign in to continue")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    // Primary path: scan with the official Discord app. Far more
                    // reliable than email+password, which usually hits a CAPTCHA.
                    VStack(spacing: 10) {
                        Button { showQR = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "qrcode.viewfinder").font(.title3)
                                Text("Scan QR Code to Sign In").fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                        }
                        .background(Palette.accent.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)

                        Text("Approve from Discord on your phone — nothing to type.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    HStack {
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(.secondary)
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                    }
                    .padding(.horizontal, 32)

                    VStack(spacing: 14) {
                        VStack(spacing: 0) {
                            TextField("Email or Phone", text: $email)
                                .textContentType(.username).keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding()
                            Divider().padding(.leading)
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .padding()
                        }
                        .background(Palette.secondaryGroupedBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        if let error {
                            Text(error).font(.footnote).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: submit) {
                            HStack {
                                if busy { ProgressView() }
                                Text("Log In with Password").fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .background(Palette.secondaryGroupedBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(busy || email.isEmpty || password.isEmpty)

                        Button("Use a login token instead") { showToken = true }
                            .font(.subheadline)
                    }
                    .padding(.horizontal)

                    #if DEBUG
                    Button {
                        model.accountStore.upsert(
                            Account(id: "1000", token: "demo", username: "you", globalName: "You",
                                    discriminator: "0", avatar: nil, addedAt: Date()), makeActive: true)
                        model.loadDemo()
                    } label: {
                        Label("Explore demo workspace", systemImage: "sparkles").font(.subheadline)
                    }
                    #endif
                    Spacer(minLength: 20)
                }
            }
            .themedBackground()
            .sheet(isPresented: Binding(get: { mfaTicket != nil }, set: { if !$0 { mfaTicket = nil } })) { mfaSheet }
            .sheet(isPresented: $showToken) { TokenSheet() }
            .sheet(isPresented: $showQR) { QRLoginView() }
        }
    }

    private var mfaSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("000000", text: $mfaCode)
                        .keyboardType(.numberPad).multilineTextAlignment(.center)
                        .font(.system(.title, design: .monospaced))
                } header: {
                    Text("Two-Factor Authentication")
                } footer: {
                    Text("Enter the 6-digit code from your authenticator app.")
                }
                Section {
                    Button(action: submitMFA) {
                        HStack { if busy { ProgressView() }; Text("Verify") }.frame(maxWidth: .infinity)
                    }.disabled(mfaCode.count < 6 || busy)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Verify").navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(300)])
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                switch try await model.login(email: email, password: password) {
                case .success(let t): try await model.addAccount(token: t)
                case .mfa(let ticket, _, _): mfaTicket = ticket
                case .captcha: error = "Discord requires a CAPTCHA here. Use “Use a login token instead.”"
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func submitMFA() {
        guard let ticket = mfaTicket else { return }
        busy = true; error = nil
        Task {
            do { try await model.completeMFA(code: mfaCode, ticket: ticket); mfaTicket = nil }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Token-based sign in — the reliable path around login captchas.
struct TokenSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste token", text: $token, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Your token is stored only in this device's keychain and never leaves your phone.")
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section {
                    Button(action: add) {
                        HStack { if busy { ProgressView() }; Text("Add Account") }.frame(maxWidth: .infinity)
                    }.disabled(token.isEmpty || busy)
                }
            }
            .navigationTitle("Sign in with Token").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func add() {
        busy = true; error = nil
        Task {
            do { try await model.addAccount(token: token); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
