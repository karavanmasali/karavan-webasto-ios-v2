import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: HeaterController

    @State private var showScanner = false
    @State private var showLeaveConfirmation = false
    @State private var showThermostatConfirmation = false

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    telemetryCard
                    manualCard
                    thermostatCard
                    leaveCard
                    debugCard
                    safetyCard
                }
                .padding()
            }
            .navigationTitle("Karavan Webasto")
            .sheet(isPresented: $showScanner) {
                ScannerView()
                    .environmentObject(controller)
            }
            .alert("Otomatik termostatı aç?", isPresented: $showThermostatConfirmation) {
                Button("Vazgeç", role: .cancel) {}
                Button("Etkinleştir") {
                    controller.setThermostatEnabled(true)
                }
            } message: {
                Text("İlk testleri karavandayken yap. Uygulama, hedefte normal STOP/CLEAR komutu; alt eşikte normal START komutu gönderir.")
            }
            .alert("Karavandan ayrılıyor musun?", isPresented: $showLeaveConfirmation) {
                Button("Vazgeç", role: .cancel) {}
                Button("Otomasyonu kapat ve STOP ver", role: .destructive) {
                    controller.leaveCaravan()
                }
            } message: {
                Text("Isıtıcı çalışıyorsa normal STOP/CLEAR komutu gönderilir. CLEAR tamamlanmadan ana 12V beslemeyi kesme.")
            }
        }
    }

    private var connectionCard: some View {
        GroupBox("Bağlantı") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(controller.isReady ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)

                    Text(controller.connectionStatus)
                        .font(.subheadline)

                    Spacer()
                }

                if !controller.connectedName.isEmpty {
                    Text(controller.connectedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if controller.isConnected {
                        Button("Durumu Yenile") {
                            controller.requestStatus()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Bağlantıyı Kes") {
                            controller.disconnect()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Isıtıcıyı Bul") {
                            showScanner = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var telemetryCard: some View {
        GroupBox("Canlı Durum") {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.telemetry.statusText)
                            .font(.title3.bold())

                        if let mode = controller.telemetry.modeRaw {
                            Text("Mod kodu: \(mode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    metric("Ortam", value: temperature(controller.telemetry.cabinTemperature))
                    metric("Kasa", value: temperature(controller.telemetry.caseTemperature))
                    metric("Voltaj", value: voltage(controller.telemetry.supplyVoltage))
                    metric("Panel hedefi", value: controller.telemetry.setTemperature.map { "\($0)°C" } ?? "—")
                }

                HStack(spacing: 14) {
                    stateChip("Pompa", active: controller.telemetry.pumpActive)
                    stateChip("Fan", active: controller.telemetry.fanActive)
                    stateChip("Kızdırma", active: controller.telemetry.glowPlugActive)
                }

                if controller.telemetry.errorCode != 0 {
                    Text("Cihaz hata bildiriyor: \(controller.telemetry.errorCode). Otomatik START yapılmaz.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var manualCard: some View {
        GroupBox("Manuel Kontrol") {
            HStack(spacing: 12) {
                Button {
                    controller.manualStart()
                } label: {
                    Label("START", systemImage: "flame.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.isReady)

                Button(role: .destructive) {
                    controller.manualStop()
                } label: {
                    Label("STOP / CLEAR", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.isReady)
            }
        }
    }

    private var thermostatCard: some View {
        GroupBox("Otomatik Termostat") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    "Otomasyonu etkinleştir",
                    isOn: Binding(
                        get: { controller.thermostatEnabled },
                        set: { newValue in
                            if newValue {
                                showThermostatConfirmation = true
                            } else {
                                controller.setThermostatEnabled(false)
                            }
                        }
                    )
                )

                Divider()

                Stepper(
                    value: Binding(
                        get: { controller.startTemperature },
                        set: { controller.setStartTemperature($0) }
                    ),
                    in: 5...33
                ) {
                    HStack {
                        Text("START")
                        Spacer()
                        Text("≤ \(controller.startTemperature)°C")
                            .font(.headline.monospacedDigit())
                    }
                }

                Stepper(
                    value: Binding(
                        get: { controller.stopTemperature },
                        set: { controller.setStopTemperature($0) }
                    ),
                    in: (controller.startTemperature + 2)...35
                ) {
                    HStack {
                        Text("STOP")
                        Spacer()
                        Text("≥ \(controller.stopTemperature)°C")
                            .font(.headline.monospacedDigit())
                    }
                }

                Text("Örnek 20/25: ortam 25°C üzerinde 20 saniye kalırsa normal STOP/CLEAR; cihaz tamamen OFF olduktan sonra ortam 20°C veya altına düştüğünde normal START.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Son işlem: \(controller.lastAction)")
                    .font(.caption)
            }
        }
    }

    private var leaveCard: some View {
        Button(role: .destructive) {
            showLeaveConfirmation = true
        } label: {
            Label("Karavandan Ayrıldım", systemImage: "car.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
    }

    private var debugCard: some View {
        GroupBox("Tanılama") {
            DisclosureGroup("Teknik kayıtları göster") {
                VStack(alignment: .leading, spacing: 8) {
                    if !controller.telemetry.rawPacketHex.isEmpty {
                        Text("Son HeatGenie paketi")
                            .font(.caption.bold())

                        Text(controller.telemetry.rawPacketHex)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }

                    ForEach(Array(controller.logs.prefix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var safetyCard: some View {
        GroupBox("Beta notu") {
            Text("Bu sürüm özellikle mevcut HeatGenie/Boygu kontrolcünü değiştirmeden denemek için hazırlandı. HeatGenie protokolünde yerleşik Auto Start/Stop ayarı herkese açık şekilde doğrulanmadığı için uygulama bunu tahmin ederek karta yazmaz; termostatı kendi START ve normal STOP/CLEAR komutlarıyla uygular. iOS uygulaması zorla kapatılırsa veya Bluetooth bağlantısı koparsa otomatik START çalışmaz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stateChip(_ title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)

            Text(title)
                .font(.caption)
        }
    }

    private func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°C", value)
    }

    private func voltage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f V", value)
    }
}

private struct ScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: HeaterController

    var body: some View {
        NavigationStack {
            List {
                if controller.discovered.isEmpty {
                    HStack {
                        ProgressView()
                        Text("HeatGenie cihazı aranıyor…")
                    }
                }

                ForEach(controller.discovered) { device in
                    Button {
                        controller.connect(to: device.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.id.uuidString)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Isıtıcı Seç")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                controller.startScan()
            }
            .onDisappear {
                controller.stopScan()
            }
        }
    }
}
