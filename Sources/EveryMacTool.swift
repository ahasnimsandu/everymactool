import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import IOKit.usb
import Darwin
import CoreGraphics
import Charts
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct EveryMacToolApp: App {
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("showWatts") private var showWatts = true
    @AppStorage("menuIcon") private var menuIcon = "bolt.fill"
    @AppStorage("magsafeStatusColor") private var magsafeStatusColor = "amber"

    var body: some Scene {
        MenuBarExtra {
            DashboardView(monitor: monitor)
                .frame(width: 560, height: 680)
                .background(.ultraThinMaterial)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: menuIcon).foregroundStyle(statusColor(for: magsafeStatusColor))
                if showWatts, monitor.current.inputWatts > 0 {
                    Text("\(Int(monitor.current.inputWatts.rounded()))W")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct PowerReading: Identifiable {
    let id = UUID()
    let time: Date
    let input: Double
    let load: Double
    let battery: Double
    let rx: Double
    let tx: Double
}

struct USBPeripheral: Identifiable {
    let id: String
    let name: String
    let vendor: String
    let product: String
    let speed: String
    let location: String
}

struct DisplayInfo: Identifiable {
    let id: UInt32
    let name: String
    let resolution: String
    let refresh: String
    let isMain: Bool
}

struct NetworkRate: Identifiable {
    let id: String
    let name: String
    let received: Double
    let sent: Double
}

struct SystemEvent: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
    let icon: String
    let tint: Color
}

struct Snapshot {
    var charge = 0.0
    var charging = false
    var inputWatts = 0.0
    var systemLoad = 0.0
    var batteryWatts = 0.0
    var batteryCapacityWh = 0.0
    var health = 0.0
    var cycles = 0
    var adapterName = "No adapter detected"
    var adapterWatts = 0.0
    var adapterVoltage = 0.0
    var adapterCurrent = 0.0
    var activeProfile = ""
    var profiles: [String] = []
    var negotiatedProfileIndex = -1
    var batteryTime = "—"
    var peripherals: [USBPeripheral] = []
    var displays: [DisplayInfo] = []
    var network: [NetworkRate] = []
    var totalRx = 0.0
    var totalTx = 0.0
    var updated = Date()
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var current = Snapshot()
    @Published var history: [PowerReading] = []
    @Published var status = "Starting monitor"
    @Published var sessionInputWh = 0.0
    @Published var sessionLoadWh = 0.0
    @Published var sessionBatteryWh = 0.0
    @Published var events: [SystemEvent] = []
    @Published var performanceMode = false
    private var timer: Timer?
    private var previousNetwork: [String: (UInt64, UInt64)] = [:]
    private var lastTick = Date()
    private var lastEnergyTick = Date()
    private var lastHardwareScan = Date.distantPast
    private var lastHistorySample = Date.distantPast
    private var hasInitialSample = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setRefreshInterval(_ seconds: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: min(10, max(0.25, seconds)), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var snapshot = Snapshot()
        snapshot.updated = Date()
        readBattery(&snapshot)
        if Date().timeIntervalSince(lastHardwareScan) >= 5 {
            snapshot.peripherals = readUSBDevices()
            snapshot.displays = readDisplays()
            lastHardwareScan = Date()
        } else {
            snapshot.peripherals = current.peripherals
            snapshot.displays = current.displays
        }
        snapshot.network = readNetwork()
        snapshot.totalRx = snapshot.network.reduce(0) { $0 + $1.received }
        snapshot.totalTx = snapshot.network.reduce(0) { $0 + $1.sent }
        let energyInterval = min(max(Date().timeIntervalSince(lastEnergyTick), 0), 30)
        if energyInterval > 0 {
            sessionInputWh += snapshot.inputWatts * energyInterval / 3600
            sessionLoadWh += snapshot.systemLoad * energyInterval / 3600
            sessionBatteryWh += snapshot.batteryWatts * energyInterval / 3600
        }
        lastEnergyTick = Date()
        if hasInitialSample {
            let wasConnected = current.adapterWatts > 0
            let isConnected = snapshot.adapterWatts > 0
            if !wasConnected && isConnected { addEvent("Power connected · \(snapshot.adapterName)", icon: "powerplug.fill", tint: .green) }
            if wasConnected && !isConnected { addEvent("External power disconnected", icon: "powerplug", tint: .orange) }
            if current.charging != snapshot.charging && isConnected {
                addEvent(snapshot.charging ? "Battery charging started" : "Battery charging paused", icon: snapshot.charging ? "battery.100percent" : "pause.circle.fill", tint: snapshot.charging ? .green : .orange)
            }
            if current.charge < 100 && snapshot.charge >= 100 { addEvent("Battery reached full charge", icon: "checkmark.circle.fill", tint: .green) }
        } else {
            addEvent("Live monitoring started", icon: "waveform.path", tint: .cyan)
            hasInitialSample = true
        }
        current = snapshot
        let remain = snapshot.inputWatts - snapshot.systemLoad
        let balance = snapshot.charging ? "Charging · +\(formatWatts(max(0, snapshot.batteryWatts))) W" : (snapshot.charge > 0 ? "Battery · −\(formatWatts(abs(snapshot.batteryWatts))) W" : "Power source unavailable")
        status = "\(balance)  ·  Input \(formatWatts(snapshot.inputWatts)) W  ·  Load \(formatWatts(snapshot.systemLoad)) W  ·  Headroom \(formatWatts(remain)) W"
        if Date().timeIntervalSince(lastHistorySample) >= 2 {
            history.append(PowerReading(time: Date(), input: snapshot.inputWatts, load: snapshot.systemLoad, battery: abs(snapshot.batteryWatts), rx: snapshot.totalRx, tx: snapshot.totalTx))
            lastHistorySample = Date()
        }
        if history.count > 90 { history.removeFirst(history.count - 90) }
    }

    private func addEvent(_ message: String, icon: String, tint: Color) {
        events.insert(SystemEvent(message: message, icon: icon, tint: tint), at: 0)
        if events.count > 12 { events.removeLast(events.count - 12) }
    }

    var adaptiveForecast: String {
        guard history.count >= 4, current.batteryCapacityWh > 0 else { return "Collecting battery trend…" }
        let values = history.suffix(15).map(\.battery).filter { $0 > 0.2 }
        guard let first = values.first else { return "Not enough power signal for an estimate" }
        let smoothed = values.dropFirst().reduce(first) { $0 + ($1 - $0) * 0.24 }
        guard smoothed > 0.2 else { return "Not enough power signal for an estimate" }
        let charging = current.charging
        let energyWh = current.batteryCapacityWh * (charging ? max(0, 100 - current.charge) : current.charge) / 100
        let taper = charging ? (current.charge >= 85 ? 1.65 : current.charge >= 70 ? 1.35 : 1.12) : 1.0
        let minutes = energyWh / smoothed * 60 * taper
        guard minutes.isFinite, minutes >= 1, minutes < 24 * 60 else { return "Estimate unavailable" }
        let quality = values.count >= 12 ? "Adaptive · 30-second trend" : "Early estimate · trend building"
        return "~\(formatDuration(minutes)) \(charging ? "to full" : "remaining") · \(quality)"
    }

    var chargingTrend: String {
        let values = Array(history.suffix(12).map(\.battery))
        guard values.count >= 8 else { return "Building recent trend" }
        let half = values.count / 2
        let early = values.prefix(half).reduce(0, +) / Double(half)
        let recent = values.suffix(half).reduce(0, +) / Double(half)
        guard early > 0.2 else { return "Stable · waiting for charge activity" }
        let change = (recent - early) / early * 100
        let activity = current.charging ? "Charge rate" : "Drain rate"
        if change > 12 { return "\(activity) rising · +\(Int(change))%" }
        if change < -12 { return "\(activity) easing · \(Int(abs(change)))%" }
        return "\(activity) steady · recent trend"
    }

    private func readBattery(_ out: inout Snapshot) {
        guard let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")) as io_service_t? else { return }
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        func number(_ key: String) -> Double { (value(key) as? NSNumber)?.doubleValue ?? 0 }
        let batteryData = value("BatteryData") as? [String: Any] ?? [:]
        func batteryNumber(_ key: String) -> Double { (batteryData[key] as? NSNumber)?.doubleValue ?? number(key) }
        out.charge = number("CurrentCapacity")
        let fullCharge = batteryNumber("FullChargeCapacity")
        let designCapacity = batteryNumber("DesignCapacity")
        out.health = fullCharge > 0 && designCapacity > 0 ? min(100, fullCharge / designCapacity * 100) : number("MaxCapacity")
        out.cycles = Int(number("CycleCount"))
        out.charging = (value("IsCharging") as? Bool) ?? false
        if let dict = value("PowerTelemetryData") as? [String: Any] {
            out.inputWatts = ((dict["SystemPowerIn"] as? NSNumber)?.doubleValue ?? 0) / 1000
            out.systemLoad = ((dict["SystemLoad"] as? NSNumber)?.doubleValue ?? 0) / 1000
            out.batteryWatts = ((dict["BatteryPower"] as? NSNumber)?.doubleValue ?? 0) / 1000
        }
        if out.batteryWatts == 0 { out.batteryWatts = number("BatteryPower") / 1000 }
        let batteryVoltage = number("Voltage")
        if fullCharge > 0 && batteryVoltage > 0 { out.batteryCapacityWh = fullCharge * batteryVoltage / 1_000_000 }
        if let adapter = value("AdapterDetails") as? [String: Any] {
            out.adapterName = adapter["Name"] as? String ?? "USB-C power adapter"
            out.adapterWatts = (adapter["Watts"] as? NSNumber)?.doubleValue ?? 0
            out.adapterVoltage = (adapter["AdapterVoltage"] as? NSNumber)?.doubleValue ?? 0
            out.adapterCurrent = (adapter["Current"] as? NSNumber)?.doubleValue ?? 0
            out.negotiatedProfileIndex = (adapter["UsbHvcHvcIndex"] as? NSNumber)?.intValue ?? -1
            if let menu = adapter["UsbHvcMenu"] as? [[String: Any]] {
                out.profiles = menu.compactMap { p in
                    guard let mv = p["MaxVoltage"] as? NSNumber, let ma = p["MaxCurrent"] as? NSNumber else { return nil }
                    let v = mv.doubleValue / 1000, a = ma.doubleValue / 1000
                    return String(format: "%.0f V  ·  %.2f A  ·  %.0f W", v, a, v * a)
                }
            }
            let v = out.adapterVoltage / 1000, a = out.adapterCurrent / 1000
            out.activeProfile = v > 0 ? String(format: "%.0f V · %.2f A · %.1f W negotiated", v, a, v * a) : "Negotiated contract unavailable"
        }
        let eta = number("AvgTimeToFull")
        if eta > 0 && eta < 65535 { out.batteryTime = "~\(Int(eta / 60))h \(Int(eta) % 60)m to full" }
    }

    private func readUSBDevices() -> [USBPeripheral] {
        var result: [USBPeripheral] = []
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            let matching = IOServiceMatching(className)
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
                func str(_ keys: [String]) -> String { for key in keys { if let s = prop(key) as? String, !s.isEmpty { return s } }; return "" }
                let product = str(["USB Product Name", "kUSBProductString", "Product Name"])
                let vendor = str(["USB Vendor Name", "kUSBVendorString", "Manufacturer"])
                var registryID: UInt64 = 0
                _ = IORegistryEntryGetRegistryEntryID(service, &registryID)
                let id = String(registryID)
                if result.contains(where: { $0.id == id }) { continue }
                let speedNum = (prop("Device Speed") as? NSNumber)?.intValue ?? (prop("Speed") as? NSNumber)?.intValue ?? 0
                let speed = speedNum > 0 ? "USB link · \(speedNum)" : "Speed not reported"
                let loc = (prop("locationID") as? NSNumber).map { String(format: "0x%08X", $0.uint32Value) } ?? "—"
                result.append(USBPeripheral(id: id, name: product.isEmpty ? (vendor.isEmpty ? "USB device" : vendor + " device") : product, vendor: vendor.isEmpty ? "Not reported" : vendor, product: product.isEmpty ? "Not reported" : product, speed: speed, location: loc))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func readDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let w = mode?.width ?? 0, h = mode?.height ?? 0
            let hz = mode?.refreshRate ?? 0
            let name = CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "External display"
            return DisplayInfo(id: id, name: name, resolution: "\(w) × \(h)", refresh: hz > 0 ? String(format: "%.0f Hz", hz) : "Variable / not reported", isMain: CGDisplayIsMain(id) != 0)
        }
    }

    private func readNetwork() -> [NetworkRate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var now: [String: (UInt64, UInt64)] = [:]
        var output: [NetworkRate] = []
        let elapsed = max(Date().timeIntervalSince(lastTick), 0.5)
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var seen = Set<String>()
        while let item = ptr {
            defer { ptr = item.pointee.ifa_next }
            guard let data = item.pointee.ifa_data?.assumingMemoryBound(to: if_data.self), let cName = item.pointee.ifa_name else { continue }
            let name = String(cString: cName)
            guard seen.insert(name).inserted else { continue }
            let rx = UInt64(data.pointee.ifi_ibytes), tx = UInt64(data.pointee.ifi_obytes)
            now[name] = (rx, tx)
            if let old = previousNetwork[name] {
                let down = Double(rx >= old.0 ? rx - old.0 : 0) / elapsed
                let up = Double(tx >= old.1 ? tx - old.1 : 0) / elapsed
                output.append(NetworkRate(id: name, name: interfaceName(name), received: down, sent: up))
            } else { output.append(NetworkRate(id: name, name: interfaceName(name), received: 0, sent: 0)) }
        }
        previousNetwork = now; lastTick = Date()
        return output.filter { !$0.id.hasPrefix("lo") }.sorted { $0.received + $0.sent > $1.received + $1.sent }
    }

    private func interfaceName(_ name: String) -> String {
        if name.hasPrefix("en") { return name == "en0" ? "Wi-Fi / Ethernet (\(name))" : "Network (\(name))" }
        if name.hasPrefix("utun") { return "VPN tunnel (\(name))" }
        if name.hasPrefix("awdl") { return "Apple Wireless Direct Link" }
        if name.hasPrefix("bridge") { return "Bridge (\(name))" }
        return name
    }
}

func formatDuration(_ minutes: Double) -> String {
    let total = Int(minutes.rounded())
    return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
}

func formatInterval(_ seconds: Double) -> String {
    let value = seconds < 1 ? String(format: "%.2f", seconds) : String(format: "%.1f", seconds).replacingOccurrences(of: ".0", with: "")
    return "\(value) sec"
}

func statusColor(for value: String) -> Color {
    switch value {
    case "green": .green
    case "cyan": .cyan
    case "violet": .purple
    default: .orange
    }
}

func formatWatts(_ n: Double) -> String { n < 10 ? String(format: "%.1f", n) : String(format: "%.0f", n) }
func formatRate(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1f MB/s", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0f KB/s", n / 1_000) }
    return String(format: "%.0f B/s", n)
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", power = "Power", devices = "Devices", network = "Network", diagnostics = "Diagnostics", settings = "Settings"
    var id: String { rawValue }
    var icon: String { switch self { case .overview: "square.grid.2x2.fill"; case .power: "bolt.fill"; case .devices: "cable.connector"; case .network: "arrow.left.arrow.right"; case .diagnostics: "waveform.path.ecg"; case .settings: "gearshape.fill" } }
}

struct DashboardView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var page: Page = .overview
    @State private var showMoreAnalysis = false
    @State private var quickSummary = "Tap below for a one-sentence read of your Mac's current power and battery status."
    @State private var writingSummary = false
    @AppStorage("showWatts") private var showWatts = true
    @AppStorage("menuIcon") private var menuIcon = "bolt.fill"
    @AppStorage("proMode") private var proMode = false
    @AppStorage("hideEmpty") private var hideEmpty = false
    @AppStorage("showCharts") private var showCharts = true
    @AppStorage("refreshSeconds") private var refreshSeconds = 2.0
    @AppStorage("performanceMode") private var performanceMode = false
    @AppStorage("glassIntensity") private var glassIntensity = 0.72
    @AppStorage("magsafeStatusColor") private var magsafeStatusColor = "amber"

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 4) {
                ForEach(Page.allCases.filter { $0 != .diagnostics || proMode }) { item in
                    Button { withAnimation(.snappy(duration: 0.22)) { page = item } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 15, weight: .medium))
                            Text(item.rawValue).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(page == item ? Color.accentColor : .secondary)
                        .background(page == item ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch page {
                    case .overview: overview
                    case .power: powerView
                    case .devices: devicesView
                    case .network: networkView
                    case .diagnostics: diagnosticsView
                    case .settings: settingsView
                    }
                }.padding(18)
            }
            Divider().opacity(0.45)
            footer
        }
        .background(.ultraThinMaterial.opacity(glassIntensity))
        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        .modifier(GlassPanel(intensity: glassIntensity))
        .animation(.snappy(duration: 0.28), value: page)
        .onAppear {
            monitor.performanceMode = performanceMode
            monitor.setRefreshInterval(performanceMode ? max(4, refreshSeconds) : refreshSeconds)
        }
        .onChange(of: proMode) { _, enabled in
            if !enabled && page == .diagnostics { page = .overview }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 25)).symbolRenderingMode(.palette).foregroundStyle(statusColor(for: magsafeStatusColor), .white.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text("EveryMacTool").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("DEVELOPED BY AHAS NIMSANDU").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.0).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(.green).frame(width: 7, height: 7).shadow(color: .green.opacity(0.7), radius: 5).symbolEffect(.pulse, options: .repeating)
            Text("LIVE").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.green)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Quit EveryMacTool")
        }.padding(.horizontal, 19).padding(.vertical, 14)
    }

    private var overview: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                MetricCard(title: "BATTERY", value: "\(Int(monitor.current.charge))%", caption: monitor.current.charging ? "Charging" : "On battery", icon: "battery.75percent", tint: .green)
                MetricCard(title: "CHARGING INPUT", value: "\(formatWatts(monitor.current.inputWatts)) W", caption: monitor.current.adapterWatts > 0 ? "Adapter rated \(Int(monitor.current.adapterWatts)) W" : "No adapter", icon: "arrow.down.to.line", tint: .cyan)
                MetricCard(title: "SYSTEM LOAD", value: "\(formatWatts(monitor.current.systemLoad)) W", caption: "Live system draw", icon: "cpu", tint: .orange)
            }
            SectionCard(title: "Power balance", subtitle: "Live energy flow · updated at your selected interval", icon: "bolt.fill") {
                HStack(spacing: 16) {
                    Gauge(value: min(1, monitor.current.inputWatts / max(monitor.current.adapterWatts, 1))) { Text("Adapter") } currentValueLabel: { Text("\(formatWatts(monitor.current.inputWatts)) W") }
                        .gaugeStyle(.accessoryCircular).tint(.cyan).frame(width: 90, height: 90)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(monitor.current.adapterName)", systemImage: "powerplug.fill").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(monitor.current.activeProfile).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Text(monitor.current.charging ? "Input currently exceeds system load. Battery is gaining energy." : "Battery is supplying the system load.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            SectionCard(title: "Quick Mac read", subtitle: "A short, on-device summary of current telemetry", icon: "apple.intelligence") {
                Text(quickSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Button {
                    Task { await writeQuickSummary() }
                } label: {
                    Label(writingSummary ? "Writing…" : "Write with Apple Intelligence", systemImage: writingSummary ? "ellipsis" : "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(writingSummary)
                Text("Uses Apple's on-device model when available; otherwise a private local summary. No telemetry is uploaded.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if showCharts { SectionCard(title: "Energy trend", subtitle: "Input, system load and battery power", icon: "chart.xyaxis.line") {
                Chart {
                    ForEach(monitor.history) { item in
                        AreaMark(x: .value("Time", item.time), y: .value("Watts", item.input), series: .value("Series", "Adapter input")).foregroundStyle(.cyan.opacity(0.12))
                        LineMark(x: .value("Time", item.time), y: .value("Watts", item.input), series: .value("Series", "Adapter input")).foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("Time", item.time), y: .value("Watts", item.load), series: .value("Series", "System load")).foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }.chartLegend(.visible).chartYAxisLabel("W").frame(height: 150)
            } }
            HStack(spacing: 12) {
                MetricCard(title: monitor.current.charging ? "SMART CHARGE FORECAST" : "SMART BATTERY FORECAST", value: monitor.adaptiveForecast.components(separatedBy: " · ").first ?? monitor.adaptiveForecast, caption: monitor.chargingTrend, icon: "sparkles", tint: .mint)
                MetricCard(title: "BATTERY HEALTH", value: "\(Int(monitor.current.health))%", caption: "\(monitor.current.cycles) cycles", icon: "heart.fill", tint: .pink)
            }
            HStack(spacing: 12) {
                MetricCard(title: "NETWORK IN", value: formatRate(monitor.current.totalRx), caption: "Aggregate receive", icon: "arrow.down", tint: .blue)
                MetricCard(title: "NETWORK OUT", value: formatRate(monitor.current.totalTx), caption: "Aggregate send", icon: "arrow.up", tint: .purple)
            }
            SectionCard(title: "Power analysis", subtitle: "Adaptive estimates from live battery telemetry", icon: "sparkles") {
                HStack {
                    Text(monitor.adaptiveForecast).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(2)
                    Spacer(minLength: 5)
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) { showMoreAnalysis.toggle() }
                    } label: {
                        Label(showMoreAnalysis ? "See less" : "See more", systemImage: showMoreAnalysis ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.plain).foregroundStyle(.cyan)
                }
                if showMoreAnalysis {
                    Divider().opacity(0.45)
                    VStack(spacing: 8) {
                        DataRow(name: "Charge / drain trend", value: monitor.chargingTrend)
                        DataRow(name: "macOS time estimate", value: monitor.current.batteryTime)
                        DataRow(name: "Battery transfer", value: "\(formatWatts(abs(monitor.current.batteryWatts))) W", accent: monitor.current.charging ? .green : .orange)
                        DataRow(name: "Adapter power headroom", value: "\(formatWatts(monitor.current.inputWatts - monitor.current.systemLoad)) W", accent: .cyan)
                        DataRow(name: "Adapter utilization", value: monitor.current.adapterWatts > 0 ? "\(Int((monitor.current.inputWatts / monitor.current.adapterWatts * 100).rounded()))%" : "Not connected")
                        DataRow(name: "Energy received this session", value: String(format: "%.3f Wh", monitor.sessionInputWh))
                        if proMode {
                            DataRow(name: "Negotiated profile", value: monitor.current.activeProfile)
                            DataRow(name: "Battery capacity basis", value: String(format: "%.1f Wh", monitor.current.batteryCapacityWh))
                            DataRow(name: "Adapter voltage / current", value: String(format: "%.2f V · %.2f A", monitor.current.adapterVoltage / 1000, monitor.current.adapterCurrent / 1000))
                        }
                    }
                    Text("Forecasts use local telemetry and a smoothed recent power trend. They adjust as workload and charging behavior change.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let issue = optimizationHint {
                SectionCard(title: "Optimization insight", subtitle: "Based on live power readings", icon: "sparkles") {
                    Label(issue, systemImage: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor
    private func writeQuickSummary() async {
        writingSummary = true
        defer { writingSummary = false }
        let reading = monitor.current
        let fallback = localQuickSummary(for: reading)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let sentence = try await requestSummary(for: reading, model: LanguageModelSession(instructions: Self.summaryInstructions))
                quickSummary = sentence.isEmpty ? fallback : sentence
                return
            } catch {
                // If Apple's on-device model fails, try Apple's Private Cloud Compute model where supported.
            }
        }
#if EVERYMAC_HAS_PCC
        if #available(macOS 27.0, *), PrivateCloudComputeLanguageModel.isAvailable {
            do {
                let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: Self.summaryInstructions)
                let sentence = try await requestSummary(for: reading, model: session)
                quickSummary = sentence.isEmpty ? fallback : sentence
                return
            } catch {
                quickSummary = "Apple's cloud model couldn't complete the summary. \(fallback)"
                return
            }
        }
#endif
        #endif
        quickSummary = "Apple Intelligence models aren't available here; using a local summary. \(fallback)"
    }

    private static let summaryInstructions = "Write exactly one concise, plain-language sentence describing the Mac's current power and battery condition using only the supplied measurements. Avoid unsupported causes, advice, or certainty. Do not invent values."

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func requestSummary(for reading: Snapshot, model: LanguageModelSession) async throws -> String {
        let prompt = "Battery: \(Int(reading.charge))%. Charging: \(reading.charging ? "yes" : "no"). Battery power: \(formatWatts(abs(reading.batteryWatts))) W. Adapter input: \(formatWatts(reading.inputWatts)) W. System load: \(formatWatts(reading.systemLoad)) W. Battery health: \(Int(reading.health))%. Time estimate: \(reading.batteryTime)."
        let response = try await model.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    private func localQuickSummary(for reading: Snapshot) -> String {
        if reading.charging {
            return "Your Mac is charging at \(formatWatts(abs(reading.batteryWatts))) W while drawing \(formatWatts(reading.systemLoad)) W for system activity, with the battery at \(Int(reading.charge))%."
        }
        return "Your Mac is running on battery at \(Int(reading.charge))%, with a current battery draw of \(formatWatts(abs(reading.batteryWatts))) W and an estimated \(reading.batteryTime)."
    }

    private var optimizationHint: String? {
        let s = monitor.current
        guard s.adapterWatts > 0, s.systemLoad > s.inputWatts * 0.9 else { return nil }
        return "System load is close to adapter input. Heavy workloads may slow charging; pause demanding tasks or use a higher-capacity compatible adapter."
    }

    private var powerView: some View {
        VStack(spacing: 13) {
            if showCharts { SectionCard(title: "Power Monitor", subtitle: "Measured telemetry from the Mac power controller", icon: "waveform.path") {
                Chart {
                    ForEach(monitor.history) { item in
                        LineMark(x: .value("Time", item.time), y: .value("Input", item.input), series: .value("Power", "Adapter input")).foregroundStyle(.cyan)
                        LineMark(x: .value("Time", item.time), y: .value("Load", item.load), series: .value("Power", "System load")).foregroundStyle(.orange)
                        LineMark(x: .value("Time", item.time), y: .value("Battery", item.battery), series: .value("Power", "Battery transfer")).foregroundStyle(.green)
                    }
                }.chartLegend(.visible).frame(height: 220)
            } }
            SectionCard(title: "Charging vs. drain", subtitle: "Instantaneous power; positive battery power means charging", icon: "arrow.left.arrow.right") {
                DataRow(name: "Adapter input", value: "\(formatWatts(monitor.current.inputWatts)) W")
                DataRow(name: "System load", value: "\(formatWatts(monitor.current.systemLoad)) W")
                DataRow(name: monitor.current.charging ? "Battery charging rate" : "Battery discharge rate", value: "\(formatWatts(abs(monitor.current.batteryWatts))) W", accent: .green)
                DataRow(name: "Adapter headroom", value: "\(formatWatts(monitor.current.inputWatts - monitor.current.systemLoad)) W", accent: .cyan)
                Text("Input power is measured at the system power controller. It is not a per-port or per-device meter.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
            }
            SectionCard(title: "Adaptive battery forecast", subtitle: "Local trend smoothing · private and offline", icon: "sparkles") {
                Text(monitor.adaptiveForecast).font(.system(size: 16, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                DataRow(name: "Recent charging trend", value: monitor.chargingTrend)
                DataRow(name: "macOS estimate", value: monitor.current.batteryTime)
                Text("The app estimate blends recent battery power with remaining pack capacity and applies a charge-taper allowance. Actual time changes with temperature, workload and battery management.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SectionCard(title: "Battery charge limit", subtitle: "Native macOS battery protection", icon: "battery.100percent") {
                Text("Apple silicon Macs on macOS Tahoe 26.4 or later support a system charge limit from 80% to 100%. macOS manages and enforces this limit.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open Battery Settings", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.cyan)
                Text("EveryMacTool opens Apple's control panel; it does not override the system's charging policy.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SectionCard(title: "Battery health", subtitle: "Pack-level diagnostics", icon: "battery.100") {
                DataRow(name: "Charge", value: "\(Int(monitor.current.charge))%")
                DataRow(name: "Maximum capacity", value: "\(Int(monitor.current.health))%")
                DataRow(name: "Cycle count", value: "\(monitor.current.cycles)")
                DataRow(name: "Estimated time", value: monitor.current.batteryTime)
            }
            SectionCard(title: "Session energy", subtitle: "Accumulated since EveryMacTool opened", icon: "chart.bar.xaxis") {
                DataRow(name: "Adapter energy received", value: String(format: "%.3f Wh", monitor.sessionInputWh), accent: .cyan)
                DataRow(name: "System energy used", value: String(format: "%.3f Wh", monitor.sessionLoadWh), accent: .orange)
                DataRow(name: "Battery energy change", value: String(format: "%+.3f Wh", monitor.sessionBatteryWh), accent: monitor.sessionBatteryWh >= 0 ? .green : .red)
                Text("Session totals reset when you quit the app; they are estimates integrated from the Mac's live power telemetry.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SectionCard(title: "Power events", subtitle: "Recent connection and charging changes", icon: "clock.arrow.circlepath") {
                if monitor.events.isEmpty { Text("Waiting for system events…").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(monitor.events.prefix(proMode ? 10 : 4)) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.icon).foregroundStyle(event.tint).frame(width: 18)
                        Text(event.message).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(event.time, style: .time).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            SectionCard(title: "Adapter negotiation", subtitle: "USB Power Delivery capability from macOS", icon: "cable.connector") {
                DataRow(name: "Adapter", value: monitor.current.adapterName)
                DataRow(name: "Maximum rated", value: "\(Int(monitor.current.adapterWatts)) W")
                DataRow(name: "Active contract", value: monitor.current.activeProfile)
                ForEach(Array(monitor.current.profiles.enumerated()), id: \.offset) { index, profile in
                    HStack { Image(systemName: index == monitor.current.negotiatedProfileIndex ? "checkmark.circle.fill" : "circle").foregroundStyle(index == monitor.current.negotiatedProfileIndex ? .green : .secondary); Text(profile).font(.system(size: 11, design: .monospaced)); Spacer() }
                }
            }
        }
    }

    private var devicesView: some View {
        VStack(spacing: 13) {
            SectionCard(title: "Connected devices", subtitle: "USB devices visible to macOS · \(monitor.current.peripherals.count) found", icon: "cable.connector") {
                if monitor.current.peripherals.isEmpty { EmptyState(icon: "cable.connector.slash", title: "Nothing connected", detail: "Plug in a USB device to see its identity and link details.") }
                ForEach(monitor.current.peripherals) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.cyan); Text(item.name).font(.system(size: 13, weight: .semibold)); Spacer(); Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.green) }
                        if proMode {
                            DataRow(name: "Vendor", value: item.vendor)
                            DataRow(name: "Product", value: item.product)
                            DataRow(name: "Link speed", value: item.speed)
                            DataRow(name: "Port location", value: item.location)
                        }
                        Divider().opacity(0.35)
                        Label("Individual device power draw is not published by macOS USB APIs.", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
            SectionCard(title: "Displays", subtitle: "Active display modes · resolution and refresh", icon: "display") {
                if monitor.current.displays.isEmpty { EmptyState(icon: "display", title: "No display data", detail: "Display mode information is unavailable right now.") }
                ForEach(monitor.current.displays) { display in
                    VStack(spacing: 6) {
                        HStack { Text(display.name).font(.system(size: 13, weight: .semibold)); if display.isMain { Text("MAIN").font(.system(size: 9, weight: .bold)).foregroundStyle(.cyan) }; Spacer() }
                        DataRow(name: "Resolution", value: display.resolution)
                        DataRow(name: "Refresh rate", value: display.refresh)
                    }.padding(.vertical, 4)
                }
                Label("Cable lane count, pin map and link bandwidth are not exposed through public macOS display APIs.", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
            }
            SectionCard(title: "Port map", subtitle: "Ports discovered by the system", icon: "point.3.connected.trianglepath.dotted") {
                DataRow(name: "USB devices", value: "\(monitor.current.peripherals.count) connected")
                DataRow(name: "MagSafe / USB-C charging", value: monitor.current.adapterWatts > 0 ? "Active · \(monitor.current.adapterWatts.formatted(.number.precision(.fractionLength(0)))) W adapter" : "No external power")
                Text("Empty physical port count and per-port current are not consistently available to third-party macOS apps.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 5)
            }
        }
    }

    private var networkView: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                MetricCard(title: "TOTAL DOWNLOAD", value: formatRate(monitor.current.totalRx), caption: "All interfaces", icon: "arrow.down.circle.fill", tint: .cyan)
                MetricCard(title: "TOTAL UPLOAD", value: formatRate(monitor.current.totalTx), caption: "All interfaces", icon: "arrow.up.circle.fill", tint: .purple)
            }
            if proMode { SectionCard(title: "Live interface traffic", subtitle: "Bytes per second · sampled at your selected interval", icon: "arrow.left.arrow.right") {
                if monitor.current.network.isEmpty { EmptyState(icon: "network", title: "Waiting for interfaces", detail: "Network counters will appear after the first sample.") }
                ForEach(visibleNetwork) { item in
                    VStack(spacing: 5) {
                        HStack { Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.cyan); Text(item.name).font(.system(size: 12, weight: .semibold)); Spacer() }
                        DataRow(name: "↓ Received", value: formatRate(item.received), accent: .cyan)
                        DataRow(name: "↑ Sent", value: formatRate(item.sent), accent: .purple)
                    }.padding(.vertical, 5)
                }
            } }
            if showCharts { SectionCard(title: "Network activity", subtitle: "Recent aggregate throughput · upload and download", icon: "chart.xyaxis.line") {
                Chart {
                    ForEach(monitor.history) { item in
                        LineMark(x: .value("Time", item.time), y: .value("Rate", item.rx), series: .value("Direction", "Download")).foregroundStyle(.cyan)
                        LineMark(x: .value("Time", item.time), y: .value("Rate", item.tx), series: .value("Direction", "Upload")).foregroundStyle(.purple)
                    }
                }.chartLegend(.visible).frame(height: 150)
                Text("Traffic totals include system services and background applications; macOS does not identify the originating app here without additional network extensions.").font(.system(size: 10)).foregroundStyle(.secondary)
            } }
        }
    }

    private var diagnosticsView: some View {
        VStack(spacing: 13) {
            SectionCard(title: "Negotiation diagnostics", subtitle: "What the power controller reports about this link", icon: "waveform.path.ecg") {
                DataRow(name: "Connection", value: monitor.current.adapterWatts > 0 ? "Power active" : "No charging adapter")
                DataRow(name: "Charger identity", value: monitor.current.adapterName)
                DataRow(name: "Negotiated contract", value: monitor.current.activeProfile)
                DataRow(name: "Power input", value: "\(formatWatts(monitor.current.inputWatts)) W")
                DataRow(name: "Adapter ceiling", value: "\(Int(monitor.current.adapterWatts)) W")
                if proMode {
                    DataRow(name: "Adapter voltage", value: String(format: "%.2f V", monitor.current.adapterVoltage / 1000))
                    DataRow(name: "Adapter current", value: String(format: "%.2f A", monitor.current.adapterCurrent / 1000))
                }
                Text(monitor.current.adapterWatts > monitor.current.inputWatts * 1.4 ? "Adapter has available capacity. Actual input varies with charge level, temperature, and system demand." : "Input is near the adapter's reported capacity. System load can reduce power available to charge the battery.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            SectionCard(title: "Cable diagnostics", subtitle: "USB-C cable identity and signaling", icon: "cable.connector") {
                EmptyState(icon: "cable.connector", title: "Cable chip data unavailable", detail: "macOS does not expose USB-C e-marker identity, cable pin maps, orientation, or cable-rated current to ordinary apps. The active charger contract above is measured from the power controller.")
            }
            SectionCard(title: "Display diagnostics", subtitle: "Current display mode", icon: "display") {
                if monitor.current.displays.isEmpty { Text("No active display mode reported.").foregroundStyle(.secondary) }
                ForEach(monitor.current.displays) { d in DataRow(name: d.name + (d.isMain ? " · Main" : ""), value: "\(d.resolution) @ \(d.refresh)") }
                Text("Display link lane details and cable bandwidth are not available through public APIs.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SectionCard(title: "Measurement notes", subtitle: "Understand the readings", icon: "info.circle") {
                Label("Battery and adapter values come from AppleSmartBattery power telemetry.", systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green)
                Label("USB power is not metered per accessory by macOS.", systemImage: "minus.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Label("USB-C cable e-marker fields are not publicly readable.", systemImage: "minus.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Label("Ethernet, Wi-Fi, and virtual interface rates use kernel byte counters.", systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green)
            }
        }
    }

    private var settingsView: some View {
        VStack(spacing: 13) {
            SectionCard(title: "Dashboard", subtitle: "Tune the menu bar panel", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("Interface mode").font(.system(size: 12, weight: .semibold)); Spacer(); Text(proMode ? "PRO" : "SIMPLE").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(proMode ? .cyan : .secondary) }
                    Picker("Interface mode", selection: $proMode) {
                        Text("Simple").tag(false)
                        Text("Pro").tag(true)
                    }.pickerStyle(.segmented)
                    Text(proMode ? "Advanced telemetry, adaptive forecasts, per-interface traffic, USB identifiers and diagnostics are visible." : "Key charging, battery, device and network readings stay uncluttered.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Toggle("Show charts", isOn: $showCharts)
                Toggle("Hide inactive network interfaces", isOn: $hideEmpty)
                VStack(alignment: .leading) { HStack { Text("Refresh interval"); Spacer(); Text(formatInterval(performanceMode ? max(4, refreshSeconds) : refreshSeconds)).foregroundStyle(.secondary) }; Slider(value: $refreshSeconds, in: 0.25...10, step: 0.25).onChange(of: refreshSeconds) { _, value in monitor.setRefreshInterval(performanceMode ? max(4, value) : value) } }
            }
            SectionCard(title: "Performance", subtitle: "Keep the panel responsive on busy Macs", icon: "speedometer") {
                Toggle("Performance mode", isOn: $performanceMode)
                    .onChange(of: performanceMode) { _, enabled in
                        monitor.performanceMode = enabled
                        monitor.setRefreshInterval(enabled ? max(4, refreshSeconds) : refreshSeconds)
                    }
                Button {
                    performanceMode = true
                    monitor.performanceMode = true
                    refreshSeconds = max(4, refreshSeconds)
                    monitor.setRefreshInterval(refreshSeconds)
                } label: {
                    Label("Optimize dashboard now", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.cyan)
                Text(performanceMode ? "Using a lighter 4-second sampling cadence. This changes EveryMacTool only." : "Reduces refresh work and chart redraws if the panel feels slow. It does not alter macOS power or background apps.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SectionCard(title: "Liquid glass", subtitle: "Adjust the panel's frosted translucency", icon: "drop.halffull") {
                HStack { Text("Clearer").font(.system(size: 10)).foregroundStyle(.secondary); Slider(value: $glassIntensity, in: 0.25...1.0).accessibilityLabel("Liquid glass intensity"); Text("More frosted").font(.system(size: 10)).foregroundStyle(.secondary) }
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(.cyan.opacity(0.14))
                    RoundedRectangle(cornerRadius: 13).fill(.ultraThinMaterial.opacity(glassIntensity))
                    HStack { Image(systemName: "sparkles").foregroundStyle(.cyan); Text("Glass preview").font(.system(size: 11, weight: .semibold)); Spacer(); Text("\(Int(glassIntensity * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }.padding(.horizontal, 12)
                }.frame(height: 42).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.12), lineWidth: 1))
            }
            SectionCard(title: "MagSafe indicator", subtitle: "Choose EveryMacTool's status glow", icon: "cable.connector") {
                HStack(spacing: 14) {
                    colorChoice("amber", label: "Amber")
                    colorChoice("green", label: "Green")
                    colorChoice("cyan", label: "Cyan")
                    colorChoice("violet", label: "Violet")
                    Spacer()
                    Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 25)).symbolRenderingMode(.palette).foregroundStyle(statusColor(for: magsafeStatusColor), .white.opacity(0.8))
                }
                Text("This changes the icon and glow inside EveryMacTool only. macOS controls the physical MagSafe charger LED.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SectionCard(title: "Menu bar", subtitle: "Customize the always-visible status item", icon: "menubar.rectangle") {
                Toggle("Show charging watts", isOn: $showWatts)
                Picker("Icon", selection: $menuIcon) {
                    Label("Power", systemImage: "bolt.fill").tag("bolt.fill")
                    Label("Plug", systemImage: "powerplug.fill").tag("powerplug.fill")
                    Label("Battery", systemImage: "battery.75percent").tag("battery.75percent")
                    Label("Cable", systemImage: "cable.connector").tag("cable.connector")
                }.pickerStyle(.segmented)
            }
            SectionCard(title: "About measurements", subtitle: "Privacy and accuracy", icon: "checkmark.shield") {
                Text("EveryMacTool reads local macOS power, USB registry, display and network counters. It sends no telemetry. Some port, cable-chip and accessory-power details are not published by macOS. Developed by Ahas Nimsandu.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Refresh now") { monitor.refresh() }.buttonStyle(.borderedProminent).tint(.cyan)
            }
        }
    }

    private var visibleNetwork: [NetworkRate] {
        hideEmpty ? monitor.current.network.filter { $0.received > 0 || $0.sent > 0 } : monitor.current.network
    }

    private func colorChoice(_ value: String, label: String) -> some View {
        Button { magsafeStatusColor = value } label: {
            Circle().fill(statusColor(for: value)).frame(width: 20, height: 20)
                .overlay(Circle().stroke(.white.opacity(magsafeStatusColor == value ? 0.95 : 0.22), lineWidth: magsafeStatusColor == value ? 2 : 1).padding(-3))
        }.buttonStyle(.plain).help(label).accessibilityLabel("Set in-app status color to \(label)")
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(.green).frame(width: 5, height: 5)
            Text(monitor.status).font(.system(size: 9, weight: .medium, design: .rounded)).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(Date.now, style: .time).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).help("Quit EveryMacTool")
        }.padding(.horizontal, 15).padding(.vertical, 9)
    }
}

struct MetricCard: View {
    let title: String; let value: String; let caption: String; let icon: String; let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: icon).foregroundStyle(tint); Spacer(); Circle().fill(tint.opacity(0.8)).frame(width: 5, height: 5) }
            Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 21, weight: .bold, design: .rounded)).contentTransition(.numericText()).minimumScaleFactor(0.7).lineLimit(1)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

struct SectionCard<Content: View>: View {
    let title: String; let subtitle: String; let icon: String; @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.cyan).frame(width: 28, height: 28).background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 14, weight: .bold, design: .rounded)); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
            }
            content
        }.padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 17, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.075), lineWidth: 1))
    }
}

struct DataRow: View {
    let name: String; let value: String; var accent: Color = .primary
    var body: some View { HStack(spacing: 10) { Text(name).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(minLength: 4); Text(value).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(accent).multilineTextAlignment(.trailing).lineLimit(2) } }
}

struct EmptyState: View {
    let icon: String; let title: String; let detail: String
    var body: some View { VStack(spacing: 7) { Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary); Text(title).font(.system(size: 14, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity).padding(.vertical, 14) }
}

struct SettingsView: View {
    @AppStorage("showWatts") private var showWatts = true
    @AppStorage("proMode") private var proMode = false
    @AppStorage("showCharts") private var charts = true
    @AppStorage("hideEmpty") private var hideEmpty = false
    var body: some View {
        Form {
            Toggle("Show charging watts in menu bar", isOn: $showWatts)
            Picker("Interface mode", selection: $proMode) {
                Text("Simple").tag(false)
                Text("Pro").tag(true)
            }.pickerStyle(.segmented)
            Toggle("Show charts", isOn: $charts)
            Toggle("Hide inactive interfaces", isOn: $hideEmpty)
        }.padding(20).frame(width: 360)
    }
}

struct GlassPanel: ViewModifier {
    let intensity: Double
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.cyan.opacity(intensity * 0.14)), in: .rect(cornerRadius: 23)).opacity(0.88 + intensity * 0.12)
        } else {
            content.background(.ultraThinMaterial.opacity(intensity), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        }
    }
}
