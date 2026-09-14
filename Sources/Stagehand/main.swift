import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--diagnose-start") || CommandLine.arguments.contains("--diagnose-ribbon") {
    Task { @MainActor in
        let model = StagehandModel()
        print(await model.diagnoseStartup(includeSettings: CommandLine.arguments.contains("--diagnose-ribbon")))
        application.terminate(nil)
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--diagnose-focus"),
          CommandLine.arguments.indices.contains(index + 1) {
    Task { @MainActor in
        await FocusDiagnostics.run(bundleIdentifier: CommandLine.arguments[index + 1])
        application.terminate(nil)
    }
} else {
    application.delegate = delegate
}
application.run()
