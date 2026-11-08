import AppKit
import Foundation
import PhosphorCore
import Testing
@testable import Resonance

@MainActor
struct JobWatcherTests {
    private func sync(running: Bool, error: String? = nil, bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0) -> HvscSyncStatus {
        HvscSyncStatus(root: "/hvsc", running: running, error: error, current: "",
                       filesDone: 0, filesTotal: 0, bytesDone: bytesDone, bytesTotal: bytesTotal)
    }

    private func scan(done: UInt32, total: UInt32 = 10_000, failed: UInt32 = 0,
                      paused: Bool = false, finished: Bool = false) -> FingerprintScanStatus {
        FingerprintScanStatus(running: !finished, paused: paused, finished: finished, pass: 1,
                              total: total, done: done, failed: failed, revision: 0, error: nil)
    }

    // MARK: Notices

    @Test func aFinishedDownloadNamesItsRelease() {
        var notices = JobNotices()
        #expect(notices.observe(sync: sync(running: true), scan: nil, release: 85).isEmpty)
        let done = notices.observe(sync: sync(running: false), scan: nil, release: 85)
        #expect(done == [.downloadFinished(release: 85)])
        #expect(done.first?.title == "HVSC 85 Is Ready")
    }

    @Test func aFailedDownloadSaysWhy() {
        var notices = JobNotices()
        _ = notices.observe(sync: sync(running: true), scan: nil, release: nil)
        #expect(notices.observe(sync: sync(running: false, error: "No network"), scan: nil, release: nil)
            == [.downloadFailed("No network")])
    }

    /// The person who canceled it knows.
    @Test func aCanceledDownloadIsQuiet() {
        // What src/hvsc_sync.rs reports, word for word.
        #expect(JobNotices.canceled == "Cancelled")
        var notices = JobNotices()
        _ = notices.observe(sync: sync(running: true), scan: nil, release: nil)
        #expect(notices.observe(sync: sync(running: false, error: JobNotices.canceled), scan: nil, release: nil).isEmpty)
    }

    @Test func aResultFromBeforeWatchingIsQuiet() {
        var notices = JobNotices()
        #expect(notices.observe(sync: sync(running: false), scan: scan(done: 10_000, finished: true), release: nil).isEmpty)
    }

    @Test func eachEndIsAnnouncedOnce() {
        var notices = JobNotices()
        _ = notices.observe(sync: sync(running: true), scan: scan(done: 0), release: nil)
        #expect(notices.observe(sync: sync(running: false), scan: scan(done: 10_000, finished: true), release: nil).count == 2)
        #expect(notices.observe(sync: sync(running: false), scan: scan(done: 10_000, finished: true), release: nil).isEmpty)
    }

    /// The published set does most of it in one go; the scan was still long.
    @Test func aLongScanIsAnnouncedAfterThePublishedSetShortensIt() {
        var notices = JobNotices()
        _ = notices.observe(sync: nil, scan: scan(done: 0), release: nil)
        _ = notices.observe(sync: nil, scan: scan(done: 9_990), release: nil)
        #expect(notices.observe(sync: nil, scan: scan(done: 10_000, finished: true), release: nil) == [.scanFinished])
    }

    @Test func aShortScanIsQuiet() {
        var notices = JobNotices()
        _ = notices.observe(sync: nil, scan: scan(done: 9_500), release: nil)
        #expect(notices.observe(sync: nil, scan: scan(done: 10_000, finished: true), release: nil).isEmpty)
    }

    // MARK: Clicking a notice

    @Test func aDownloadsNoticeOpensTheHomeAndAScansDoesnt() {
        #expect(JobNotice.section(forNotification: JobNotice.downloadFinished(release: 85).id) == .hvscHome)
        #expect(JobNotice.section(forNotification: JobNotice.downloadFailed("No network").id) == .hvscHome)
        #expect(JobNotice.section(forNotification: JobNotice.scanFinished.id) == nil)
    }

    // MARK: Asking permission

    @Test func asksOnlyWithALongJobRunning() {
        #expect(JobNotices.worthAsking(sync: sync(running: true), scan: nil))
        #expect(JobNotices.worthAsking(sync: nil, scan: scan(done: 0)))
        #expect(!JobNotices.worthAsking(sync: nil, scan: scan(done: 0, paused: true)))
        #expect(!JobNotices.worthAsking(sync: nil, scan: scan(done: 9_500)))
        #expect(!JobNotices.worthAsking(sync: sync(running: false), scan: scan(done: 10_000, finished: true)))
        #expect(!JobNotices.worthAsking(sync: nil, scan: nil))
    }

    // MARK: Dock progress

    @Test func theDownloadGoesBeforeTheScan() {
        let fraction = JobProgress.fraction(sync: sync(running: true, bytesDone: 1, bytesTotal: 4), scan: scan(done: 5_000))
        #expect(fraction == 0.25)
    }

    @Test func aDownloadWithoutATotalShowsAnEmptyBar() {
        #expect(JobProgress.fraction(sync: sync(running: true), scan: nil) == 0)
    }

    @Test func theScanCountsWhatItGaveUpOn() {
        #expect(JobProgress.fraction(sync: sync(running: false), scan: scan(done: 4_000, failed: 1_000)) == 0.5)
    }

    @Test func nothingShowsWhenPausedFinishedOrIdle() {
        #expect(JobProgress.fraction(sync: nil, scan: scan(done: 1, paused: true)) == nil)
        #expect(JobProgress.fraction(sync: nil, scan: scan(done: 10_000, finished: true)) == nil)
        #expect(JobProgress.fraction(sync: nil, scan: scan(done: 0, total: 0)) == nil)
        #expect(JobProgress.fraction(sync: nil, scan: nil) == nil)
    }

    // MARK: Dock menu

    @Test func withNothingPlayingTheMenuOffersOnlyWhatApplies() {
        let store = PlayerStore(defaults: UserDefaults(suiteName: "dock-menu-tests")!, defaultHvscRoot: nil) { _ in PreviewCore.empty }
        let menu = DockMenu.make(store: store, library: LibraryStore(player: store),
                                 fingerprints: FingerprintStore(player: store))
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Play", "Next Track", "Previous Track", "Play Something Like This", "Drift From This Tune", "Surprise Me"])
        #expect(items.allSatisfy { !$0.isEnabled })
    }
}
