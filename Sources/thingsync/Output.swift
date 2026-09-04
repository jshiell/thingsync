import Foundation
import ThingsyncCore

/// Plan/refusal lines to stdout, "State error: …"/"Reminders error: …" to
/// stderr -- the same stream discipline `test_cli.py` pins via `capsys`.
struct StandardOutput: Output {
    func out(_ line: String) {
        print(line)
    }

    func err(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
