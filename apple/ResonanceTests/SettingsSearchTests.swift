import Testing
@testable import Resonance

struct SettingsSearchTests {
    @Test func emptySearchShowsTheSidebarAsItIs() {
        #expect(SettingsSearch.pages(matching: "") == nil)
        #expect(SettingsSearch.pages(matching: "   ") == nil)
    }

    @Test func findsSettingsByEveryWordIgnoringCase() {
        #expect(SettingsSearch.pages(matching: "UPDATES automatic") == [.updates])
        #expect(SettingsSearch.pages(matching: "stereo") == [.playback])
    }

    @Test func findsSettingsByOtherWords() {
        #expect(SettingsSearch.pages(matching: "dark mode") == [.appearance])
        #expect(SettingsSearch.pages(matching: "vim") == [.general])
        #expect(SettingsSearch.pages(matching: "terminal") == [.integrations])
    }

    @Test func aPageNameAloneFindsThePage() {
        #expect(SettingsSearch.pages(matching: "storage") == [.storage])
    }

    @Test func pagesComeInTheSidebarsOrder() throws {
        let pages = try #require(SettingsSearch.pages(matching: "download"))
        let order = SettingsPage.groups.flatMap(\.pages)
        let indices = pages.compactMap { order.firstIndex(of: $0) }
        #expect(indices == indices.sorted())
        #expect(pages.count > 1)
    }

    @Test func nothingMatchesNonsense() {
        #expect(SettingsSearch.pages(matching: "zxqv") == [])
    }

    @Test func everyPageHasSettingsToFind() {
        for page in SettingsPage.allCases {
            #expect(!page.items.isEmpty, "\(page) has nothing to search")
            #expect(page.items.allSatisfy { $0.page == page })
        }
    }
}
