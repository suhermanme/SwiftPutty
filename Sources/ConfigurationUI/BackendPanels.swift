import Foundation
import PuTTYBridge
import SwiftUI

// The Connection/Serial, Telnet, Rlogin and SUPDUP panels (M11), as
// config.c builds them for PuTTY's Unix backends.

/// An edit box for a serial line, with a menu of the serial devices
/// present (`/dev/cu.*`, macOS's call-out devices) to fill it in.
struct SerialLineField: View {
    let label: String
    @Binding var line: String

    var body: some View {
        HStack(spacing: 4) {
            PlainTextField(label: label, text: $line)
            Menu {
                let devices = ConfigurationModel.serialDevices()
                if devices.isEmpty {
                    Button("No serial devices found") {}.disabled(true)
                }
                ForEach(devices, id: \.self) { device in
                    Button(device) { line = device }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Serial devices")
        }
    }
}

// MARK: - Connection/Serial

struct SerialPanel: View {
    let model: ConfigurationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // config.c: the line cannot be changed mid-session; the rest
            // can (serial_reconfig).
            if !model.isMidSession {
                SettingsGroup(title: "Select a serial line") {
                    Text("Serial line to connect to")
                    SerialLineField(label: "Serial line to connect to",
                                    line: Binding(get: { model.string(.serialLine) },
                                                  set: { model.setString(.serialLine, $0) }))
                }
            }
            SettingsGroup(title: "Configure the serial line") {
                NumberSetting(model: model, label: "Speed (baud)", keyword: .serialSpeed)
                NumberSetting(model: model, label: "Data bits", keyword: .serialDataBits)
                // Saved in half bits.
                FixedPointSetting(model: model, label: "Stop bits", keyword: .serialStopHalfbits,
                                  denominator: 2)
                // The Unix backend's serial_parity_mask and
                // serial_flow_mask: no Mark/Space parity, no DSR/DTR.
                PopupSetting(model: model, label: "Parity", keyword: .serialParity,
                             options: [("None", "0"), ("Odd", "1"), ("Even", "2")])
                PopupSetting(model: model, label: "Flow control", keyword: .serialFlowControl,
                             options: [("None", "0"), ("XON/XOFF", "1"), ("RTS/CTS", "2")])
            }
        }
    }
}

// MARK: - Connection/Telnet

struct TelnetPanel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: "Telnet protocol adjustments") {
            if !model.isMidSession {
                RadioSetting(model: model, label: "Handling of OLD_ENVIRON ambiguity:",
                             keyword: .rfcEnviron,
                             options: [("BSD (commonplace)", "0"), ("RFC 1408 (unusual)", "1")])
                RadioSetting(model: model, label: "Telnet negotiation mode:", keyword: .passiveTelnet,
                             options: [("Passive", "1"), ("Active", "0")])
            }
            CheckboxSetting(model: model, label: "Keyboard sends Telnet special commands",
                            keyword: .telnetKey)
            CheckboxSetting(model: model, label: "Return key sends Telnet New Line instead of ^M",
                            keyword: .telnetRet)
        }
    }
}

// MARK: - Connection/Rlogin

struct RloginPanel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: "Data to send to the server") {
            TextSetting(model: model, label: "Local username:", keyword: .localUserName)
        }
    }
}

// MARK: - Connection/SUPDUP

struct SUPDUPPanel: View {
    let model: ConfigurationModel

    var body: some View {
        SettingsGroup(title: nil) {
            TextSetting(model: model, label: "Location string", keyword: .supdupLocation)
            RadioSetting(model: model, label: "Extended ASCII Character set:", keyword: .supdupCharset,
                         options: [("None", "0"), ("ITS", "1"), ("WAITS", "2")])
            CheckboxSetting(model: model, label: "**MORE** processing", keyword: .supdupMoreProcessing)
            CheckboxSetting(model: model, label: "Terminal scrolling", keyword: .supdupScrolling)
        }
    }
}
