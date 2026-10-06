// Post only F13 to the explicitly supplied fixture browser. No global input,
// event taps, text capture, Accessibility queries, or other application access.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]), pid > 0 else { exit(2) }
let source = CGEventSource(stateID: .privateState)
while let line = readLine() {
    guard line == "probe", kill(pid, 0) == 0 else { exit(3) }
    guard CGPreflightPostEventAccess(),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: false) else {
        print("input_access_unavailable"); fflush(stdout); continue
    }
    down.postToPid(pid); up.postToPid(pid)
    print("posted"); fflush(stdout)
}
