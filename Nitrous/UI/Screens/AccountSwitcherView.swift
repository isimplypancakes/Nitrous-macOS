import SwiftUI

/// Add an account from inside the app — same credential paths as first launch
/// (email + password with MFA, or a token), presented as a native form sheet.
struct AddAccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var showQR = false
    @State private var email = ""
    @State private var password = ""
    @State private var token = ""
    @State private var mfaTicket: String?
    @State private var mfaCode = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showQR = true } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("Approve from Discord on your phone — the easiest way to add an account.")
                }

                Section {
                    Picker("Method", selection: $mode) {
                        Text("Email").tag(0)
                        Text("Token").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == 0 {
                    Section("Credentials") {
                        TextField("Email or phone", text: $email)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        if mfaTicket != nil {
                            TextField("Two-factor code", text: $mfaCode)
                        }
                    }
                } else {
                    Section {
                        TextField("Paste token", text: $token, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                    } header: {
                        Text("Login Token")
                    } footer: {
                        Text("Stored only in this device's keychain.")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 4) }
                            Text(mfaTicket != nil ? "Verify Code" : "Add Account")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(busy || !canSubmit)
                }
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Add Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showQR) { QRLoginView() }
        }
    }

    private var canSubmit: Bool {
        if mode == 1 { return !token.isEmpty }
        if mfaTicket != nil { return mfaCode.count >= 6 }
        return !email.isEmpty && !password.isEmpty
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                if mode == 1 { try await model.addAccount(token: token); dismiss() }
                else if let ticket = mfaTicket { try await model.completeMFA(code: mfaCode, ticket: ticket); dismiss() }
                else {
                    switch try await model.login(email: email, password: password) {
                    case .success(let t): try await model.addAccount(token: t); dismiss()
                    case .mfa(let ticket, _, _): mfaTicket = ticket
                    case .captcha: error = "CAPTCHA required — add this account with a token instead."
                    }
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
