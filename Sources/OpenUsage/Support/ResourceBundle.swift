import Foundation

extension Bundle {
    /// The bundle carrying OpenUsage's copied provider icons.
    ///
    /// The build system generates a `Bundle.module` for every target that carries resources. Under
    /// the Swift Build engine that accessor looks in `Bundle.main.resourceURL` first — the app's
    /// `Contents/Resources`, where the packaging scripts stage every resource bundle — so it finds
    /// the bundle in a shipped `.app`. SwiftPM's older native engine generated an accessor that
    /// looked only in the app root and in the build tree baked in at compile time, so an app
    /// packaged with it died with "Fatal error: could not load resource bundle" the first time a
    /// dependency read its resources. The scripts build with Swift Build for that reason.
    ///
    /// This accessor looks where the resource bundle actually ships first, and only falls back to
    /// `Bundle.module` for `swift run` / `swift test`, where the build path is valid.
    static let openUsageResources: Bundle = {
        let bundleName = "OpenUsage_OpenUsage.bundle"
        let containingAppResources = Bundle.main.executableURL
            .flatMap(ContainingAppBundle.url(for:))?
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        let searchBases: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            containingAppResources,
            Bundle(for: ResourceBundleToken.self).resourceURL,
            Bundle(for: ResourceBundleToken.self).bundleURL
        ]
        for case let base? in searchBases {
            guard let bundle = Bundle(url: base.appendingPathComponent(bundleName)) else { continue }
            if bundle.url(forResource: "openusage", withExtension: "svg", subdirectory: "ProviderIcons") != nil {
                return bundle
            }
            AppLog.warn(.config, "ignoring resource bundle at \(base.lastPathComponent): missing provider icons")
        }
        return .module
    }()
}

private final class ResourceBundleToken {}
