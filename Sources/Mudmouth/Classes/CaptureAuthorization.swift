import Foundation

/// Shared by the containing app and its packet tunnel. Missing or obsolete consent fails closed.
public enum CaptureAuthorization {
    public static let version = 1
    public static let key = "CaptureConsentVersion"
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: "group.jp.qleap.intrcptr")!
    }

    public enum Failure: Error { case consentRequired }

    public static var isGranted: Bool {
        isGranted(in: defaults)
    }

    public static func isGranted(in store: UserDefaults) -> Bool {
        store.integer(forKey: key) == version
    }

    public static func grant(in store: UserDefaults = defaults) {
        store.set(version, forKey: key)
    }

    public static func revoke(in store: UserDefaults = defaults) {
        store.set(0, forKey: key)
    }

    public static func requireConsent() throws {
        guard isGranted else { throw Failure.consentRequired }
    }
}
