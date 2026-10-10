import Foundation
import IOKit

/// Minimal, read-only AppleSMC reader adapted from WhatCable's MIT-licensed
/// SMCPowerReader. It reads the live battery rail (PPBR) and DC-in rail
/// (PDTR/VD0R/ID0R), which update faster than AppleSmartBattery's cached watts.
/// Source: https://github.com/darrylmorley/whatcable
struct SMCPowerInput: Sendable {
    let watts: Double
    let volts: Double
    let amps: Double
}

final class SMCPowerReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSRecursiveLock()

    init() {
        assert(MemoryLayout<SMCParamStruct>.stride == 80)
    }

    deinit { close() }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    func readBatteryDischargeWatts() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard open(), let watts = readFloat("PPBR"), watts >= 0, watts < 200 else { return nil }
        return Double(watts)
    }

    func readSystemPowerInput() -> SMCPowerInput? {
        lock.lock()
        defer { lock.unlock() }
        guard open() else { return nil }
        let volts = readFloat("VD0R") ?? 0
        let amps = readFloat("ID0R") ?? 0
        guard volts > 0 || amps > 0 else { return nil }
        let watts = readFloat("PDTR") ?? (volts * amps)
        guard watts.isFinite, watts >= 0, watts < 300 else { return nil }
        return SMCPowerInput(watts: Double(watts), volts: Double(volts), amps: Double(amps))
    }

    private func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var client: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &client) == KERN_SUCCESS else { return false }
        connection = client
        return true
    }

    private func readFloat(_ key: String) -> Float? {
        guard let bytes = readKey(key), bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bits)
        return value.isFinite ? value : nil
    }

    private func readKey(_ key: String) -> [UInt8]? {
        let chars = Array(key.utf8)
        guard chars.count == 4 else { return nil }
        let fourCC = chars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        var info = SMCParamStruct()
        info.key = fourCC
        info.data8 = 9 // get key info
        guard let infoOut = callDriver(&info) else { return nil }
        let size = infoOut.keyInfo.dataSize
        guard size > 0, size <= 32 else { return nil }

        var read = SMCParamStruct()
        read.key = fourCC
        read.keyInfo.dataSize = size
        read.keyInfo.dataType = infoOut.keyInfo.dataType
        read.data8 = 5 // read key
        guard let readOut = callDriver(&read) else { return nil }
        var payload = readOut.bytes
        return withUnsafeBytes(of: &payload) { Array($0.prefix(Int(size))) }
    }

    private func callDriver(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        return result == KERN_SUCCESS ? output : nil
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
