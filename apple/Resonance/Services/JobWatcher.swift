import AppKit
import PhosphorCore
import UserNotifications

/// What a long job has to say to someone who's looking elsewhere.
enum JobNotice: Equatable {
    case downloadFinished(release: UInt32?)
    case downloadFailed(String)
    case scanFinished

    private static let downloadID = "hvsc-download"

    /// Where clicking a notification takes you: a download's, finished or
    /// failed, to the HVSC Home. Others just bring the window forward.
    static func section(forNotification id: String) -> SidebarItem? {
        id == downloadID ? .hvscHome : nil
    }

    /// One per job, so Notification Center keeps only a job's latest.
    var id: String {
        switch self {
        case .downloadFinished, .downloadFailed: Self.downloadID
        case .scanFinished: "fingerprint-scan"
        }
    }

    var title: String {
        switch self {
        case .downloadFinished(let release): String(localized: "\(release.map { "HVSC \($0)" } ?? "HVSC") Is Ready")
        case .downloadFailed: String(localized: "The HVSC Download Stopped")
        case .scanFinished: String(localized: "Sounds Like Is Ready")
        }
    }

    var body: String {
        switch self {
        case .downloadFinished: String(localized: "The collection has finished downloading.")
        case .downloadFailed(let reason): reason
        case .scanFinished: String(localized: "Sounds Like now covers your whole collection.")
        }
    }
}

/// Turns the jobs' statuses, seen in turn, into notices: only for what ended
/// while being watched, so launching never announces an old result.
struct JobNotices {
    /// The core's error for a download someone stopped themselves.
    static let canceled = "Canceled"
    /// Subtunes left for a scan to be worth a notice or a permission prompt:
    /// a new HVSC release's few hundred pass unremarked.
    static let longScan = 1000

    private var downloading = false
    /// The most subtunes the running scan has had left.
    private var scanLeft = 0

    mutating func observe(sync: HvscSyncStatus?, scan: FingerprintScanStatus?, release: UInt32?) -> [JobNotice] {
        var notices: [JobNotice] = []
        if let sync {
            if downloading, !sync.running {
                if let error = sync.error {
                    if error != Self.canceled { notices.append(.downloadFailed(error)) }
                } else {
                    notices.append(.downloadFinished(release: release))
                }
            }
            downloading = sync.running
        }
        if let scan {
            if scan.finished {
                if scanLeft >= Self.longScan { notices.append(.scanFinished) }
                scanLeft = 0
            } else {
                scanLeft = max(scanLeft, Self.left(scan))
            }
        }
        return notices
    }

    /// Whether a job is under way that someone would want to hear about:
    /// the moment asking for permission makes sense.
    static func worthAsking(sync: HvscSyncStatus?, scan: FingerprintScanStatus?) -> Bool {
        if sync?.running == true { return true }
        guard let scan, !scan.finished, !scan.paused else { return false }
        return left(scan) >= longScan
    }

    private static func left(_ scan: FingerprintScanStatus) -> Int {
        max(Int(scan.total) - Int(scan.done) - Int(scan.failed), 0)
    }
}

/// How far the job the Dock icon shows has gotten: the download while there is
/// one, else the scan; nil with neither, or the scan paused.
enum JobProgress {
    static func fraction(sync: HvscSyncStatus?, scan: FingerprintScanStatus?) -> Double? {
        if let sync, sync.running { return sync.fraction ?? 0 }
        guard let scan, scan.running, !scan.paused, !scan.finished, scan.total > 0 else { return nil }
        return Double(Int(scan.done) + Int(scan.failed)) / Double(scan.total)
    }
}

/// Follows the HVSC download and the fingerprint scan for the Dock icon and
/// for notifications, which go out only while Resonance isn't the frontmost
/// app: in front, the window already shows it all.
final class JobWatcher: NSObject, UNUserNotificationCenterDelegate {
    private static let failedCategory = "hvsc-download-failed"
    private static let retryAction = "retry"

    private let store: PlayerStore
    private let library: LibraryStore
    private let fingerprints: FingerprintStore
    private let dock = DockProgress()
    private var notices = JobNotices()
    private var askedPermission = false

    init(store: PlayerStore, library: LibraryStore, fingerprints: FingerprintStore) {
        self.store = store
        self.library = library
        self.fingerprints = fingerprints
        super.init()
    }

    /// Call before launching finishes, to hear about a click on a
    /// notification that launched the app.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let retry = UNNotificationAction(identifier: Self.retryAction, title: String(localized: "Retry"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.failedCategory, actions: [retry], intentIdentifiers: []),
        ])
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = store.hvscSync
            _ = fingerprints.status
            _ = store.welcomeSteps
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update()
    }

    private func update() {
        let sync = store.hvscSync
        let scan = fingerprints.status
        dock.show(JobProgress.fraction(sync: sync, scan: scan))
        askPermissionIfDue(sync: sync, scan: scan)
        for notice in notices.observe(sync: sync, scan: scan, release: store.latestHvsc) where !NSApp.isActive {
            post(notice)
        }
    }

    /// Once, in front, with a long job running and onboarding out of the way.
    private func askPermissionIfDue(sync: HvscSyncStatus?, scan: FingerprintScanStatus?) {
        guard !askedPermission, store.welcomeSteps.isEmpty, NSApp.isActive,
              JobNotices.worthAsking(sync: sync, scan: scan) else { return }
        askedPermission = true
        // No sound: music is likely playing.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func post(_ notice: JobNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if case .downloadFailed = notice { content.categoryIdentifier = Self.failedCategory }
        let center = UNUserNotificationCenter.current()
        // Replacing one still in Notification Center would update it without
        // a banner.
        center.removeDeliveredNotifications(withIdentifiers: [notice.id])
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        await MainActor.run {
            if action == Self.retryAction {
                store.startHvscSync()
            } else if action == UNNotificationDefaultActionIdentifier {
                if let section = JobNotice.section(forNotification: id) {
                    store.isShowingNowPlaying = false
                    library.shownSection = section
                }
                NSApp.activate()
                MiniPlayer.openMainWindow?()
            }
        }
    }
}
