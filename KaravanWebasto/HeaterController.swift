import Foundation
import CoreBluetooth
import SwiftUI

final class HeaterController: NSObject, ObservableObject {
    @Published private(set) var discovered: [DiscoveredHeater] = []
    @Published private(set) var connectionStatus = "Bluetooth hazırlanıyor…"
    @Published private(set) var connectedName = ""
    @Published private(set) var telemetry = HeaterTelemetry()
    @Published private(set) var lastAction = "Henüz işlem yok"
    @Published private(set) var logs: [String] = []

    @Published var thermostatEnabled: Bool {
        didSet { defaults.set(thermostatEnabled, forKey: Keys.thermostatEnabled) }
    }

    @Published var startTemperature: Int {
        didSet {
            if stopTemperature < startTemperature + 2 {
                stopTemperature = startTemperature + 2
            }
            defaults.set(startTemperature, forKey: Keys.startTemperature)
        }
    }

    @Published var stopTemperature: Int {
        didSet {
            if stopTemperature < startTemperature + 2 {
                stopTemperature = startTemperature + 2
            }
            defaults.set(stopTemperature, forKey: Keys.stopTemperature)
        }
    }

    var isConnected: Bool { peripheral?.state == .connected }
    var isReady: Bool { isConnected && notifyCharacteristic != nil && writeCharacteristic != nil }

    private enum Keys {
        static let thermostatEnabled = "thermostatEnabled"
        static let startTemperature = "startTemperature"
        static let stopTemperature = "stopTemperature"
        static let selectedPeripheral = "selectedPeripheral"
    }

    private let defaults = UserDefaults.standard
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var peripheralCache: [UUID: CBPeripheral] = [:]
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var statusTimer: Timer?
    private var shouldReconnect = true

    private var lastAutomationCommandAt = Date.distantPast
    private var lastStoppedAt = Date.distantPast
    private var overStopSince: Date?

    override init() {
        let savedStart = UserDefaults.standard.object(forKey: Keys.startTemperature) as? Int ?? 20
        let savedStop = UserDefaults.standard.object(forKey: Keys.stopTemperature) as? Int ?? 25

        self.thermostatEnabled = UserDefaults.standard.bool(forKey: Keys.thermostatEnabled)
        self.startTemperature = savedStart
        self.stopTemperature = max(savedStop, savedStart + 2)

        super.init()

        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "KaravanWebasto.Central"
            ]
        )
    }

    deinit {
        statusTimer?.invalidate()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            connectionStatus = "Bluetooth açık değil"
            return
        }

        discovered.removeAll()
        peripheralCache.removeAll()
        connectionStatus = "HeatGenie cihazı aranıyor…"

        central.scanForPeripherals(
            withServices: [HeatGenieProtocol.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Tarama başladı: 181A")
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(to id: UUID) {
        guard let p = peripheralCache[id] else { return }
        stopScan()
        shouldReconnect = true
        defaults.set(id.uuidString, forKey: Keys.selectedPeripheral)
        peripheral = p
        p.delegate = self
        connectionStatus = "Bağlanıyor…"
        central.connect(p, options: nil)
    }

    func disconnect() {
        shouldReconnect = false
        statusTimer?.invalidate()

        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }

        peripheral = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        connectedName = ""
        telemetry.connected = false
        connectionStatus = "Bağlantı kesildi"
    }

    func manualStart() {
        guard isReady else {
            lastAction = "Önce ısıtıcıya bağlan"
            return
        }
        send(HeatGenieProtocol.power(true), reason: "Manuel START")
    }

    func manualStop() {
        guard isReady else {
            lastAction = "Önce ısıtıcıya bağlan"
            return
        }
        thermostatEnabled = false
        send(HeatGenieProtocol.power(false), reason: "Manuel STOP / CLEAR")
    }

    func setThermostatEnabled(_ enabled: Bool) {
        thermostatEnabled = enabled
        overStopSince = nil
        lastAction = enabled ? "Otomatik termostat etkin" : "Otomatik termostat kapalı"

        if enabled {
            requestStatus()
        }
    }

    func setStartTemperature(_ value: Int) {
        startTemperature = max(5, min(value, 33))
    }

    func setStopTemperature(_ value: Int) {
        stopTemperature = max(startTemperature + 2, min(value, 35))
    }

    func leaveCaravan() {
        thermostatEnabled = false
        overStopSince = nil
        lastAction = "Karavandan ayrılma: otomasyon kapalı"

        if isReady && (telemetry.running || telemetry.cooling) {
            send(HeatGenieProtocol.power(false), reason: "Karavandan ayrıl: STOP / CLEAR")
        }
    }

    func requestStatus() {
        guard isReady else { return }
        send(HeatGenieProtocol.statusRequest(), reason: "Durum sorgusu", quiet: true)
    }

    private func evaluateAutomation(previous: HeaterTelemetry) {
        guard thermostatEnabled, isReady else { return }
        guard telemetry.errorCode == 0 else {
            lastAction = "Otomasyon beklemede: cihaz hata bildiriyor"
            return
        }
        guard let ambient = telemetry.cabinTemperature else { return }

        if previous.running && !telemetry.running {
            lastStoppedAt = Date()
        }

        // STOP eşiği:
        // Sıcaklık hedefin üstünde en az 20 saniye kalırsa normal OFF komutu gönderilir.
        // Bu komut ana elektriği kesmez; kontrolcünün kendi CLEAR/soğutma prosedürünü başlatır.
        if ambient >= Double(stopTemperature) && telemetry.running {
            if overStopSince == nil {
                overStopSince = Date()
            }

            if let since = overStopSince,
               Date().timeIntervalSince(since) >= 20,
               Date().timeIntervalSince(lastAutomationCommandAt) >= 30 {
                send(HeatGenieProtocol.power(false), reason: "Otomatik STOP → \(stopTemperature)°C")
                lastAutomationCommandAt = Date()
                overStopSince = nil
            }
            return
        } else {
            overStopSince = nil
        }

        // START eşiği:
        // Isıtıcı tamamen OFF olmadan ve CLEAR bitmeden yeniden START verilmez.
        let fullyOff = !telemetry.running && !telemetry.cooling && telemetry.runningStep == 0
        let minimumRestElapsed = Date().timeIntervalSince(lastStoppedAt) >= 120
        let commandCooldownElapsed = Date().timeIntervalSince(lastAutomationCommandAt) >= 30

        if ambient <= Double(startTemperature),
           fullyOff,
           minimumRestElapsed,
           commandCooldownElapsed {
            send(HeatGenieProtocol.power(true), reason: "Otomatik START → \(startTemperature)°C")
            lastAutomationCommandAt = Date()
        }
    }

    private func send(_ data: Data, reason: String, quiet: Bool = false) {
        guard let p = peripheral,
              let characteristic = writeCharacteristic,
              p.state == .connected else {
            if !quiet { lastAction = "Komut gönderilemedi: bağlantı hazır değil" }
            return
        }

        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        p.writeValue(data, for: characteristic, type: type)

        if !quiet {
            lastAction = reason
            log("\(reason) → \(data.kwHexString)")
        }
    }

    private func beginStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.requestStatus()
        }
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)"
        logs.insert(line, at: 0)

        if logs.count > 80 {
            logs.removeLast(logs.count - 80)
        }
    }

    private func tryReconnectSavedPeripheral() {
        guard let idString = defaults.string(forKey: Keys.selectedPeripheral),
              let id = UUID(uuidString: idString) else {
            return
        }

        let retrieved = central.retrievePeripherals(withIdentifiers: [id])
        guard let saved = retrieved.first else { return }

        peripheral = saved
        saved.delegate = self
        shouldReconnect = true
        connectionStatus = "Kayıtlı ısıtıcıya bağlanıyor…"
        central.connect(saved, options: nil)
    }
}

extension HeaterController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionStatus = "Bluetooth hazır"
            tryReconnectSavedPeripheral()
        case .poweredOff:
            connectionStatus = "Bluetooth kapalı"
        case .unauthorized:
            connectionStatus = "Bluetooth izni verilmedi"
        case .unsupported:
            connectionStatus = "Bluetooth LE desteklenmiyor"
        default:
            connectionStatus = "Bluetooth hazırlanıyor…"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let name =
            peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "HeatGenie / Boygu"

        peripheralCache[id] = peripheral

        let item = DiscoveredHeater(id: id, name: name, rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == id }) {
            discovered[index] = item
        } else {
            discovered.append(item)
        }

        discovered.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        connectedName = peripheral.name ?? "HeatGenie / Boygu"
        connectionStatus = "Bağlandı, servis aranıyor…"
        log("Bağlandı: \(connectedName)")
        peripheral.discoverServices([HeatGenieProtocol.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionStatus = "Bağlantı başarısız"
        log("Bağlantı hatası: \(error?.localizedDescription ?? "bilinmiyor")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        statusTimer?.invalidate()
        notifyCharacteristic = nil
        writeCharacteristic = nil
        telemetry.connected = false
        connectionStatus = "Bağlantı kesildi"
        log("Bağlantı kesildi")

        if shouldReconnect {
            connectionStatus = "Yeniden bağlanılıyor…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                central.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            peripheral = restored
            restored.delegate = self
            shouldReconnect = true
            connectionStatus = "Bluetooth bağlantısı geri yükleniyor…"

            if restored.state == .connected {
                restored.discoverServices([HeatGenieProtocol.serviceUUID])
            } else {
                central.connect(restored, options: nil)
            }
        }
    }
}

extension HeaterController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Servis hatası: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        for service in services where service.uuid == HeatGenieProtocol.serviceUUID {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            log("Karakteristik hatası: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            let props = characteristic.properties

            if characteristic.uuid == HeatGenieProtocol.preferredNotifyUUID
                || props.contains(.notify)
                || props.contains(.indicate) {
                if notifyCharacteristic == nil
                    || characteristic.uuid == HeatGenieProtocol.preferredNotifyUUID {
                    notifyCharacteristic = characteristic
                }
            }

            if characteristic.uuid == HeatGenieProtocol.preferredWriteUUID
                || props.contains(.write)
                || props.contains(.writeWithoutResponse) {
                if writeCharacteristic == nil
                    || characteristic.uuid == HeatGenieProtocol.preferredWriteUUID {
                    writeCharacteristic = characteristic
                }
            }
        }

        if let notify = notifyCharacteristic {
            peripheral.setNotifyValue(true, for: notify)
            if notify.properties.contains(.read) {
                peripheral.readValue(for: notify)
            }
        }

        if notifyCharacteristic != nil && writeCharacteristic != nil {
            connectionStatus = "Kontrol hazır"
            log("181A hazır: notify=\(notifyCharacteristic!.uuid.uuidString), write=\(writeCharacteristic!.uuid.uuidString)")
            beginStatusTimer()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestStatus()
            }
        } else {
            connectionStatus = "181A bulundu ama kontrol karakteristikleri eksik"
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("BLE veri hatası: \(error.localizedDescription)")
            return
        }

        guard let value = characteristic.value else { return }

        if let parsed = HeatGenieProtocol.parseStatus(value) {
            let previous = telemetry
            telemetry = parsed
            evaluateAutomation(previous: previous)
        } else {
            log("Ham paket: \(value.kwHexString)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("Komut yazma hatası: \(error.localizedDescription)")
        }
    }
}
