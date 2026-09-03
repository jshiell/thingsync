#if canImport(Darwin)
    import Darwin
#endif
import ThingsyncCore

/// Parent pid and process name, via libproc's public C API -- no
/// subprocess and no PATH needed, which matters, because doctor has to
/// work in exactly the constrained environments where a diagnosis is most
/// needed. `proc_pidinfo`/`proc_bsdinfo` are exposed directly by the
/// Darwin module on this toolchain (confirmed directly, not assumed), so
/// unlike doctor.py's ~30-line hand-rolled `ctypes.Structure`, the C
/// struct is simply used as-is.
public let nativeProcLookup: ProcLookup = { pid in
    var info = proc_bsdinfo()
    let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard written > 0 else { return nil }

    let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return (ppid: Int32(bitPattern: info.pbi_ppid), name: name)
}
