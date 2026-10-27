import Foundation

/// Single source of truth for the app's version, shown in the dashboard footer and the About settings
/// tab. `CFBundleShortVersionString` carries the full version including any pre-release suffix
/// (e.g. `0.7.16-beta.1`), baked into the bundle by `script/build_and_run.sh` (dev, as
/// `$OPENUSAGE_VERSION-dev`) and `script/release.sh` (release). It is the same string Sparkle shows
/// in its update prompt. The fallback covers runs outside the packaged app (e.g. `swift run`, where
/// there is no Info.plist).
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.7.0"
    }
}
