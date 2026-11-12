import Foundation

/// The binary that is running, as build-app.sh stamped it. A runner's checkout
/// can differ from it, for example when the app runs from /Applications.
struct BuildIdentity: Encodable, Equatable {
    var version: String?
    var buildNumber: String?
    var executableModified: String?

    static var running: BuildIdentity { of(.main) }

    static func of(_ bundle: Bundle) -> BuildIdentity {
        let modified = bundle.executableURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return BuildIdentity(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            executableModified: modified?.ISO8601Format()
        )
    }

    var diagnosticDetails: [String: String] {
        [
            "buildVersion": version ?? "unknown",
            "buildNumber": buildNumber ?? "unknown",
            "executableModified": executableModified ?? "unknown"
        ]
    }

    static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}
