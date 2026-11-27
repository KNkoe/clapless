import Darwin
import Foundation

/// How hard the iPhone is working, sampled between calls: the nearest thing to a heat reading that
/// moves in seconds rather than minutes.
struct LoadMeter {
    private var ticks: (busy: Double, total: Double)?
    private var own: (seconds: Double, at: Double)?

    /// Share of all the processor cores in use by everything on the phone, 0...100, camera included.
    mutating func wholePhone() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // The four counters are user, system, idle and nice.
        let (user, system, idle, nice) = info.cpu_ticks
        let busy = Double(user) + Double(system) + Double(nice)
        let now = (busy: busy, total: busy + Double(idle))
        defer { ticks = now }
        guard let ticks, now.total > ticks.total else { return nil }
        return 100 * (now.busy - ticks.busy) / (now.total - ticks.total)
    }

    /// Processor time used by Clapless itself, as a percentage of one core.
    mutating func thisApp() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        let now = (seconds: seconds(usage.ru_utime) + seconds(usage.ru_stime), at: HostClock.now)
        defer { own = now }
        guard let own, now.at > own.at else { return nil }
        return 100 * (now.seconds - own.seconds) / (now.at - own.at)
    }
}
