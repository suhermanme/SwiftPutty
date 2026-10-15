import AppKit
import PuTTYBridge
import SwiftUI

// Connection/SSH sub-panels (M09), as config.c: Kex, Host keys, Cipher,
// Auth (Credentials, GSSAPI), TTY, X11, Bugs, More bugs.

/// config.c's draglist: an ordered preference list with Up and Down.
struct PreferenceListSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    /// Saved name to the name PuTTY shows.
    let names: [String: String]
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            HStack(alignment: .top) {
                List(selection: $selection) {
                    ForEach(Array(model.preferenceList(keyword).enumerated()), id: \.offset) { index, name in
                        Text(names[name] ?? name).tag(index)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 6 * 22)
                VStack(spacing: 8) {
                    Button("Up") { move(-1) }
                    Button("Down") { move(+1) }
                }
                .frame(width: 70)
            }
        }
    }

    private func move(_ offset: Int) {
        guard let index = selection else {
            model.beep()
            return
        }
        model.movePreference(keyword, at: index, by: offset)
        if model.preferenceList(keyword).indices.contains(index + offset) {
            selection = index + offset
        }
    }
}

/// A file name with a Browse… button (config.c's file selector).
struct FileSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    let panelTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            HStack {
                PlainTextField(label: label, text: Binding(get: { model.string(keyword) },
                                                           set: { model.setString(keyword, $0) }))
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.title = panelTitle
                    if panel.runModal() == .OK, let url = panel.url {
                        model.setString(keyword, url.path)
                    }
                }
            }
        }
    }
}

// MARK: - Kex

struct KexPanel: View {
    let model: ConfigurationModel
    static let names = [
        "dh-group1-sha1": "Diffie-Hellman group 1 (1024-bit)",
        "dh-group14-sha1": "Diffie-Hellman group 14 (2048-bit)",
        "dh-group15-sha512": "Diffie-Hellman group 15 (3072-bit)",
        "dh-group16-sha512": "Diffie-Hellman group 16 (4096-bit)",
        "dh-group17-sha512": "Diffie-Hellman group 17 (6144-bit)",
        "dh-group18-sha512": "Diffie-Hellman group 18 (8192-bit)",
        "dh-gex-sha1": "Diffie-Hellman group exchange",
        "rsa": "RSA-based key exchange",
        "ecdh": "ECDH key exchange",
        "ntru-curve25519": "NTRU Prime / Curve25519 hybrid kex",
        "mlkem-curve25519": "ML-KEM / Curve25519 hybrid kex",
        "mlkem-nist": "ML-KEM / NIST ECDH hybrid kex",
        "WARN": "-- warn below here --",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Key exchange algorithm options") {
                PreferenceListSetting(model: model, label: "Algorithm selection policy:",
                                      keyword: .kex, names: Self.names)
                CheckboxSetting(model: model, label: "Attempt GSSAPI key exchange",
                                keyword: .tryGSSAPIKex)
            }
            SettingsGroup(title: "Options controlling key re-exchange") {
                NumberSetting(model: model, label: "Max minutes before rekey (0 for no limit)",
                              keyword: .rekeyTime)
                NumberSetting(model: model, label: "Minutes between GSS checks (0 for never)",
                              keyword: .gssapiRekey)
                LabeledContent("Max data before rekey (0 for no limit)") {
                    PlainTextField(label: "Max data before rekey",
                                   text: Binding(get: { model.string(.rekeyBytes) },
                                                 set: { model.setString(.rekeyBytes, $0) }))
                        .frame(width: 80)
                }
                Text("(Use 1M for 1 megabyte, 1G for 1 gigabyte etc)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Host keys

struct HostKeysPanel: View {
    let model: ConfigurationModel
    static let names = [
        "ed25519": "Ed25519", "ed448": "Ed448", "ecdsa": "ECDSA", "dsa": "DSA", "rsa": "RSA",
        "WARN": "-- warn below here --",
    ]

    var body: some View {
        SettingsGroup(title: "Host key algorithm preference") {
            PreferenceListSetting(model: model, label: "Algorithm selection policy:",
                                  keyword: .hostKey, names: Self.names)
            CheckboxSetting(model: model, label: "Prefer algorithms for which a host key is known",
                            keyword: .preferKnownHostKeys)
        }
    }
}

// MARK: - Cipher

struct CipherPanel: View {
    let model: ConfigurationModel
    static let names = [
        "chacha20": "ChaCha20 (SSH-2 only)", "aesgcm": "AES-GCM (SSH-2 only)", "3des": "3DES",
        "blowfish": "Blowfish", "des": "DES", "aes": "AES (SSH-2 only)",
        "arcfour": "Arcfour (SSH-2 only)", "WARN": "-- warn below here --",
    ]

    var body: some View {
        SettingsGroup(title: "Encryption options") {
            PreferenceListSetting(model: model, label: "Encryption cipher selection policy:",
                                  keyword: .cipher, names: Self.names)
            CheckboxSetting(model: model, label: "Enable legacy use of single-DES in SSH-2",
                            keyword: .ssh2DES)
        }
    }
}

// MARK: - Auth, Credentials, GSSAPI

struct AuthPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: nil) {
                CheckboxSetting(model: model, label: "Display pre-authentication banner (SSH-2 only)",
                                keyword: .sshBanner)
                CheckboxSetting(model: model, label: "Bypass authentication entirely (SSH-2 only)",
                                keyword: .sshNoAuth)
                CheckboxSetting(model: model, label: "Disconnect if authentication succeeds trivially",
                                keyword: .sshNoTrivialAuth)
            }
            SettingsGroup(title: "Authentication methods") {
                // Pageant's role on macOS: the SSH agent at SSH_AUTH_SOCK.
                CheckboxSetting(model: model, label: "Attempt authentication using SSH agent",
                                keyword: .tryAgent)
                CheckboxSetting(model: model, label: "Attempt TIS or CryptoCard auth (SSH-1)",
                                keyword: .authTIS)
                CheckboxSetting(model: model, label: "Attempt \"keyboard-interactive\" auth (SSH-2)",
                                keyword: .authKI)
            }
            SettingsGroup(title: "Other authentication-related options") {
                CheckboxSetting(model: model, label: "Allow agent forwarding", keyword: .agentFwd)
                CheckboxSetting(model: model, label: "Allow attempted changes of username in SSH-2",
                                keyword: .changeUsername)
            }
        }
    }
}

struct CredentialsPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Public-key authentication") {
                FileSetting(model: model, label: "Private key file for authentication:",
                            keyword: .publicKeyFile, panelTitle: "Select private key file")
                FileSetting(model: model, label: "Certificate to use with the private key (optional):",
                            keyword: .detachedCertificate, panelTitle: "Select certificate file")
            }
            SettingsGroup(title: "Plugin to provide authentication responses") {
                TextSetting(model: model, label: "Plugin command to run", keyword: .authPlugin)
            }
        }
    }
}

struct GSSAPIPanel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: nil) {
            CheckboxSetting(model: model, label: "Attempt GSSAPI authentication (SSH-2 only)",
                            keyword: .authGSSAPI)
            CheckboxSetting(model: model, label: "Attempt GSSAPI key exchange (SSH-2 only)",
                            keyword: .tryGSSAPIKex)
            CheckboxSetting(model: model, label: "Allow GSSAPI credential delegation",
                            keyword: .gssapiFwd)
            PreferenceListSetting(model: model, label: "Preference order for GSSAPI libraries:",
                                  keyword: .gssLibs,
                                  names: ["libgssapi": "libgssapi (Heimdal)",
                                          "libgssapi_krb5": "libgssapi_krb5 (MIT Kerberos)",
                                          "libgss": "libgss (Sun)",
                                          "custom": "User-supplied GSSAPI library"])
            FileSetting(model: model, label: "User-supplied GSSAPI library path:",
                        keyword: .gssCustom, panelTitle: "Select library file")
        }
    }
}

// MARK: - TTY

struct TTYPanel: View {
    let model: ConfigurationModel
    @State private var selection = Set<String>()
    @State private var kind: Character = "A"
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: nil) {
                CheckboxSetting(model: model, label: "Don't allocate a pseudo-terminal", keyword: .noPTY)
            }
            SettingsGroup(title: "Terminal modes") {
                Text("Terminal modes to send:")
                List(selection: $selection) {
                    ForEach(model.terminalModes, id: \.mode) { entry in
                        HStack {
                            Text(entry.mode).frame(width: 100, alignment: .leading)
                            Text(ConfigurationModel.describeTerminalMode(entry.value))
                        }
                        .tag(entry.mode)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 6 * 22)
                HStack {
                    Picker("Value", selection: $kind) {
                        Text("Auto").tag(Character("A"))
                        Text("Nothing").tag(Character("N"))
                        Text("This:").tag(Character("V"))
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    PlainTextField(label: "Value", text: $text)
                        .frame(width: 100)
                        .disabled(kind != "V")
                    Button("Set") { model.setTerminalModes(selection, kind: kind, text: text) }
                        .disabled(selection.isEmpty)
                }
            }
        }
    }
}

// MARK: - X11

struct X11Panel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: "X11 forwarding") {
            CheckboxSetting(model: model, label: "Enable X11 forwarding", keyword: .x11Forward)
            TextSetting(model: model, label: "X display location", keyword: .x11Display)
            RadioSetting(model: model, label: "Remote X11 authentication protocol", keyword: .x11AuthType,
                         options: [("MIT-Magic-Cookie-1", "1"), ("XDM-Authorization-1", "2")])
            FileSetting(model: model, label: "X authority file for local display",
                        keyword: .x11AuthFile, panelTitle: "Select X authority file")
        }
    }
}

// MARK: - Bugs

/// sshbug_handler's drop-down: Auto / Off / On (saved 0 / 1 / 2), or
/// Off / On for workarounds that cannot be detected.
struct BugSetting: View {
    let model: ConfigurationModel
    let label: String
    let keyword: PuTTYKeyword
    var manualOnly = false

    var body: some View {
        PopupSetting(model: model, label: label, keyword: keyword,
                     options: (manualOnly ? [] : [("Auto", "0")]) + [("Off", "1"), ("On", "2")])
    }
}

struct BugsPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: "Detection of known bugs in SSH servers") {
                BugSetting(model: model, label: "Chokes on SSH-2 ignore messages", keyword: .bugIgnore2)
                BugSetting(model: model, label: "Handles SSH-2 key re-exchange badly", keyword: .bugRekey2)
                BugSetting(model: model, label: "Chokes on PuTTY's SSH-2 'winadj' requests", keyword: .bugWinadj)
                BugSetting(model: model, label: "Replies to requests on closed channels", keyword: .bugChanReq)
                BugSetting(model: model, label: "Ignores SSH-2 maximum packet size", keyword: .bugMaxPkt2)
            }
            SettingsGroup(title: "Manually enabled workarounds") {
                BugSetting(model: model, label: "Discards data sent before its greeting",
                           keyword: .bugDropStart, manualOnly: true)
                BugSetting(model: model, label: "Chokes on PuTTY's full KEXINIT",
                           keyword: .bugFilterKexinit, manualOnly: true)
            }
        }
    }
}

struct MoreBugsPanel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: "Detection of known bugs in SSH servers") {
            BugSetting(model: model, label: "Old RSA/SHA2 cert algorithm naming", keyword: .bugRSASHA2CertUserauth)
            BugSetting(model: model, label: "Requires padding on SSH-2 RSA signatures", keyword: .bugRSAPad2)
            BugSetting(model: model, label: "Only supports pre-RFC4419 SSH-2 DH GEX", keyword: .bugOldGex2)
            BugSetting(model: model, label: "Miscomputes SSH-2 HMAC keys", keyword: .bugHMAC2)
            BugSetting(model: model, label: "Misuses the session ID in SSH-2 PK auth", keyword: .bugPKSessID2)
            BugSetting(model: model, label: "Miscomputes SSH-2 encryption keys", keyword: .bugDeriveKey2)
            BugSetting(model: model, label: "Chokes on SSH-1 ignore messages", keyword: .bugIgnore1)
            BugSetting(model: model, label: "Refuses all SSH-1 password camouflage", keyword: .bugPlainPW1)
            BugSetting(model: model, label: "Chokes on SSH-1 RSA authentication", keyword: .bugRSA1)
        }
    }
}
