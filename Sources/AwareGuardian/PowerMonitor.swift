import AwareCore
import Foundation
import IOKit.ps

struct SystemPowerMonitor: Sendable {
    func sample() -> PowerSample {
        let values = batteryValues()
        return PowerSample(
            source: values.source,
            batteryPercent: values.percent,
            thermal: thermalLevel(ProcessInfo.processInfo.thermalState)
        )
    }

    private func batteryValues() -> (source: PowerSource, percent: Int) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return (.unknown, 0)
        }
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
        let state = description[kIOPSPowerSourceStateKey] as? String
        let powerSource: PowerSource = state == kIOPSACPowerValue ? .ac : (state == kIOPSBatteryPowerValue ? .battery : .unknown)
        return (powerSource, maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 0)
    }

    private func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}
