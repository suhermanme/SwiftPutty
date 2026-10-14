import PuTTYBridge

/// The PuTTY save keywords (`conf.h` `SAVE_KEYWORD`) the configuration
/// panels edit. A test checks that each one is a keyword PuTTY saves.
public enum PuTTYKeyword: String, CaseIterable, Sendable {
    case addressFamily = "AddressFamily"
    case answerback = "Answerback"
    case autoWrapMode = "AutoWrapMode"
    case bce = "BCE"
    case blinkText = "BlinkText"
    case closeOnExit = "CloseOnExit"
    case crImpliesLF = "CRImpliesLF"
    case curType = "CurType"
    case decOriginMode = "DECOriginMode"
    case eraseToScrollback = "EraseToScrollback"
    case fontName = "FontName"
    case hostName = "HostName"
    case lfImpliesCR = "LFImpliesCR"
    case localEcho = "LocalEcho"
    case localEdit = "LocalEdit"
    case logFileClash = "LogFileClash"
    case logFileName = "LogFileName"
    case logFlush = "LogFlush"
    case logHeader = "LogHeader"
    case logHost = "LogHost"
    case logType = "LogType"
    case pingInterval = "PingInterval"
    case pingIntervalSecs = "PingIntervalSecs"
    case portNumber = "PortNumber"
    case protocolName = "Protocol"
    case scrollBar = "ScrollBar"
    case scrollOnDisp = "ScrollOnDisp"
    case scrollOnKey = "ScrollOnKey"
    case scrollbackLines = "ScrollbackLines"
    case serialLine = "SerialLine"
    case sshLogOmitData = "SSHLogOmitData"
    case sshLogOmitPasswords = "SSHLogOmitPasswords"
    case tcpKeepalives = "TCPKeepalives"
    case tcpNoDelay = "TCPNoDelay"
    case termHeight = "TermHeight"
    case termWidth = "TermWidth"
    case terminalSpeed = "TerminalSpeed"
    case terminalType = "TerminalType"
    case userName = "UserName"
    case userNameFromEnvironment = "UserNameFromEnvironment"
    case winTitle = "WinTitle"
}

extension PuTTYSettings {
    subscript(keyword: PuTTYKeyword) -> String? {
        get { self[keyword.rawValue] }
        set { self[keyword.rawValue] = newValue }
    }
}
