import AppKit
import ClipExtensions

// Extension scripts run in a separate copy of this binary, which exits without touching AppKit.
if CommandLine.arguments.contains(ScriptHost.flag) {
    ScriptHost.main()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let controller = AppController()
    application.delegate = controller
    application.setActivationPolicy(.accessory)
    application.run()
}
