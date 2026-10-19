import Foundation
import CoreBluetooth

enum HeatGenieProtocol {
    static let serviceUUID = CBUUID(string: "181A")
    static let preferredNotifyUUID = CBUUID(string: "3A00")
    static let preferredWriteUUID = CBUUID(string: "3A01")

    private static let framePrefix: UInt8 = 0xAA
    private static let statusType: UInt8 = 0xF2

    // HeatGenie/Boygu command envelope used by the app-backed protocol implementation.
    private static let commandButton: UInt8 = 0x61
    private static let commandAutoUpdate: UInt8 = 0x65
    private static let buttonOn: UInt8 = 0x01
    private static let buttonOff: UInt8 = 0x02
    private static let registerArea: UInt8 = 0x02

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for value in bytes {
            for nibble in [value >> 4, value & 0x0F] {
                crc ^= UInt16(nibble) << 12
                for _ in 0..<4 {
                    if (crc & 0x8000) != 0 {
                        crc = ((crc << 1) ^ 0x1021) & 0xFFFF
                    } else {
                        crc = (crc << 1) & 0xFFFF
                    }
                }
            }
        }
        return crc
    }

    private static func frame(command: UInt8, first: UInt8, second: UInt8, third: UInt8) -> Data {
        var bytes: [UInt8] = [framePrefix, 0x00, command, first, second, third, 0x00, 0x00]
        let crc = crc16(Array(bytes.prefix(6)))
        bytes[6] = UInt8((crc >> 8) & 0xFF)
        bytes[7] = UInt8(crc & 0xFF)
        return Data(bytes)
    }

    static func statusRequest() -> Data {
        frame(command: commandAutoUpdate, first: registerArea, second: 20, third: 30)
    }

    static func power(_ enabled: Bool) -> Data {
        frame(
            command: commandButton,
            first: enabled ? buttonOn : buttonOff,
            second: 0xFF,
            third: 0x00
        )
    }

    static func parseStatus(_ data: Data) -> HeaterTelemetry? {
        let bytes = [UInt8](data)
        guard bytes.count >= 50 else { return nil }
        guard bytes[0] == framePrefix else { return nil }
        guard bytes[7] == statusType else { return nil }

        // The 40-byte HeatGenie register block begins at byte 8.
        let registers = Array(bytes[8..<48])

        func u16LE(_ index: Int) -> UInt16 {
            UInt16(registers[index]) | (UInt16(registers[index + 1]) << 8)
        }

        func i16LE(_ index: Int) -> Int16 {
            Int16(bitPattern: u16LE(index))
        }

        let state = Int(registers[0] & 0x0F)
        let flags = registers[1]

        let rawError = u16LE(20)
        var errorCode = 0
        if rawError != 0 {
            for bit in 0..<16 {
                let mask = UInt16(1) << UInt16(bit)
                if (rawError & mask) != 0 {
                    errorCode = Int(mask)
                    break
                }
            }
        }

        let unsupportedProbe = Int16(bitPattern: 32760)
        let intakeRaw = i16LE(16)
        let outletRaw = i16LE(18)

        var t = HeaterTelemetry()
        t.connected = true
        t.runningStep = state
        t.running = state != 0 && state != 5
        t.modeRaw = Int((flags >> 5) & 0x03)
        t.setLevel = Int(registers[32])
        t.setTemperature = Int(registers[33])
        t.supplyVoltage = Double(u16LE(2)) / 10.0
        t.cabinTemperature = Double(i16LE(6)) / 10.0
        t.caseTemperature = Double(i16LE(8)) / 10.0
        t.intakeTemperature = intakeRaw == unsupportedProbe ? nil : Double(intakeRaw) / 10.0
        t.outletTemperature = outletRaw == unsupportedProbe ? nil : Double(outletRaw) / 10.0
        t.errorCode = errorCode
        t.pumpActive = (flags & 0x03) != 0
        t.fanActive = (flags & 0x04) != 0
        t.glowPlugActive = (flags & 0x08) != 0
        t.usesFahrenheit = (flags & 0x10) != 0
        t.rawPacketHex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        return t
    }
}

extension Data {
    var kwHexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
