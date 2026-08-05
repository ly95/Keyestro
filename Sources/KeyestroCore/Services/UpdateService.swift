import Foundation

@MainActor
public protocol UpdateServicing: AnyObject, Sendable {
    var isConfigured: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get }
    var channel: String { get }
    var lastErrorMessage: String? { get }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool)
    func setAutomaticallyDownloadsUpdates(_ enabled: Bool)
    func setChannel(_ channel: String)
    func checkForUpdates()
}
