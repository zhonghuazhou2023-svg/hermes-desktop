#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct ConnectionDraft {
    var label = ""
    var host = ""
    var port = "22"
    var user = ""
    var hermesProfile = ""
    var customHermesHomePath = ""
    var authKind: SSHCredentialKind = .password
    var password = ""
    var privateKey = ""
    var passphrase = ""

    init() {}

    init(connection: ConnectionProfile, credential: SSHCredentialRecord) {
        label = connection.label
        host = connection.sshHost
        port = connection.sshPort.map(String.init) ?? "22"
        user = connection.sshUser
        hermesProfile = connection.hermesProfile ?? ""
        customHermesHomePath = connection.customHermesHomePath ?? ""
        authKind = connection.authKind
        password = credential.password ?? ""
        privateKey = credential.privateKey ?? ""
        passphrase = credential.passphrase ?? ""
    }

    func makeProfile(existingID: UUID?) -> ConnectionProfile {
        ConnectionProfile(
            id: existingID ?? UUID(),
            label: label,
            sshAlias: "",
            sshHost: host,
            sshPort: Int(port),
            sshUser: user,
            hermesProfile: hermesProfile.nilIfBlank,
            customHermesHomePath: customHermesHomePath.nilIfBlank,
            authKind: authKind
        )
    }

    var credential: SSHCredentialRecord {
        SSHCredentialRecord(
            password: password.nilIfBlank,
            privateKey: privateKey.nilIfBlank,
            passphrase: passphrase.nilIfBlank
        )
    }

    var trimmedHermesProfile: String? {
        guard let value = hermesProfile.nilIfBlank else { return nil }
        guard value.caseInsensitiveCompare("default") != .orderedSame else { return nil }
        return value
    }

    var trimmedCustomHermesHomePath: String? {
        guard var value = customHermesHomePath.nilIfBlank else { return nil }
        if value == "~/" {
            return "~"
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: HermesPhoneStore
    @Binding var draft: ConnectionDraft
    let editingConnectionID: UUID?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Host") {
                TextField("Label", text: $draft.label)
                TextField("Host or IP", text: $draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $draft.port)
                    .keyboardType(.numberPad)
                TextField("User", text: $draft.user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Hermes") {
                TextField("Profile (optional)", text: $draft.hermesProfile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Custom Hermes Home (optional)", text: $draft.customHermesHomePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Standard remote layout: Hermes lives in ~/.hermes, or in ~/.hermes/profiles/<name> when you choose a profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let customHermesHomePath = draft.trimmedCustomHermesHomePath {
                    Text("Custom Hermes Home override: \(customHermesHomePath). HermesPhone will use this path as HERMES_HOME for Terminal and app-driven Hermes actions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let hermesProfile = draft.trimmedHermesProfile {
                    Text("Resolved profile path: ~/.hermes/profiles/\(hermesProfile). The default Terminal shell stays host-level and auto-detects the Hermes install from the standard layout.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The default Terminal shell auto-detects Hermes from the standard layout, checking ~/.hermes first and falling back to default or available profiles when needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $draft.authKind) {
                    ForEach(SSHCredentialKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                switch draft.authKind {
                case .password:
                    SecureField("Password", text: $draft.password)
                case .privateKey:
                    TextEditor(text: $draft.privateKey)
                        .frame(minHeight: 180)
                        .font(.body.monospaced())
                    SecureField("Passphrase (optional)", text: $draft.passphrase)
                }
            }

            Section {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    Task {
                        isTesting = true
                        let message = await store.testConnection(
                            profile: draft.makeProfile(existingID: editingConnectionID),
                            credential: draft.credential
                        )
                        testResult = message
                        isTesting = false
                    }
                }
                .disabled(isTesting)

                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(editingConnectionID == nil ? "New Host" : "Edit Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let profile = draft.makeProfile(existingID: editingConnectionID)
                    store.saveConnection(
                        profile: profile,
                        credential: draft.credential,
                        makeActive: store.activeConnectionID == nil || editingConnectionID == store.activeConnectionID
                    )
                    dismiss()
                }
            }
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
