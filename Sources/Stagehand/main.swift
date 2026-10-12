import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate

/// A plain kill, Ctrl-C from a terminal, or a closed login session would end
/// the process without applicationWillTerminate, leaving windows parked
/// offscreen. Route those signals through the normal termination path so the
/// frames captured at Start are restored. The sources must outlive this scope.
let terminationSignalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { NSApp.terminate(nil) }
    }
    source.resume()
    return source
}

application.run()
