import Foundation

struct DiscoveredHeater: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct HeaterTelemetry: Equatable {
    var connected = false
    var running = false
    var runningStep: Int?
    var modeRaw: Int?
    var setLevel: Int?
    var setTemperature: Int?
    var supplyVoltage: Double?
    var cabinTemperature: Double?
    var caseTemperature: Double?
    var intakeTemperature: Double?
    var outletTemperature: Double?
    var errorCode: Int = 0
    var pumpActive = false
    var fanActive = false
    var glowPlugActive = false
    var usesFahrenheit = false
    var rawPacketHex = ""

    var cooling: Bool {
        if running { return false }
        if let step = runningStep, step != 0 { return true }
        if fanActive { return true }
        return false
    }

    var statusText: String {
        if errorCode != 0 { return "Hata \(errorCode)" }
        if cooling { return "Soğutuyor / CLEAR" }
        if running { return "Çalışıyor" }
        return "Kapalı"
    }
}
