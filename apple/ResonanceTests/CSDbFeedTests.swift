import Foundation
import Testing
@testable import Resonance

/// CSDb's feeds, as they came on 5 November 2026, trimmed to a few items.
struct CSDbFeedTests {
    private func rss(_ items: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>CSDb</title>
        <image><title>CSDb logo</title></image>
        \(items)
        </channel></rss>
        """.utf8)
    }

    @Test func readsReleases() throws {
        let feed = rss("""
        <item><title>Jan's Ballad 2 [2SID]</title>
        <link>https://csdb.dk/release/?id=265707&amp;rss</link>
        <description><![CDATA[Released by: <a href="https://csdb.dk/group/?id=308">The Supply Team</a><br />Type: <a href="https://csdb.dk/x">C64 Music</a><br /><a href="https://csdb.dk/release/?id=265707&rss"><img alt="x" src="https://csdb.dk/gfx/releases/265000/265707.png" /></a>]]></description>
        <guid>https://csdb.dk/release/?id=265707</guid>
        <pubDate>Thu, 05 Nov 2026 00:00:00 +0100</pubDate></item>
        <item><title>Round 50</title>
        <link>https://csdb.dk/release/?id=265701&amp;rss</link>
        <description><![CDATA[Released by: <a href="x">Padua</a> , <a href="y">Royal Belgian Beer Squadron</a><br />Type: <a href="z">C64 One-File Demo</a><br />]]></description>
        <guid>https://csdb.dk/release/?id=265701</guid>
        <pubDate>Thu, 05 Nov 2026 00:00:00 +0100</pubDate></item>
        """)
        let releases = CSDbFeeds.releases(from: feed)
        #expect(releases.count == 2)
        let ballad = try #require(releases.first)
        #expect(ballad.id == 265707)
        #expect(ballad.displayTitle == "Jan's Ballad 2")
        #expect(ballad.sidFormat == "2SID")
        #expect(ballad.groups == ["The Supply Team"])
        #expect(ballad.kind == "C64 Music")
        #expect(ballad.imageURL?.lastPathComponent == "265707.png")
        #expect(ballad.date != .distantPast)
        #expect(releases[1].groups == ["Padua", "Royal Belgian Beer Squadron"])
        #expect(releases[1].sidFormat == nil)
    }

    @Test func readsEvents() throws {
        let feed = rss("""
        <item><title>Yogi's &amp;amp; Flex' Melodic 2SID Compo 2026</title>
        <link>https://csdb.dk/event/?id=3679&amp;rss</link>
        <description><![CDATA[<a href="x"><img src="https://csdb.dk/gfx/events/3000/3679.jpg" width="353"></a><br /><i>- There can be only 2! :)</i><br /><br />Event type: Standalone Compo<br /><br />Held on: 1 October - 31 December 2026<br />]]></description>
        <guid>https://csdb.dk/event/?id=3679</guid>
        <pubDate>Wed, 04 Nov 2026 19:27:14 +0100</pubDate></item>
        <item><title>Comparade 2026 (Germany)</title>
        <link>https://csdb.dk/event/?id=3672&amp;rss</link>
        <description><![CDATA[<i>- Always!</i><br /><br />Event type: Demo Party<br /><br />Held on: 6 - 8 November 2026<br />]]></description>
        <guid>https://csdb.dk/event/?id=3672</guid>
        <pubDate>Wed, 04 Nov 2026 19:25:24 +0100</pubDate></item>
        """)
        let events = CSDbFeeds.events(from: feed)
        #expect(events.count == 2)
        #expect(events[0].title == "Yogi's & Flex' Melodic 2SID Compo 2026")
        #expect(events[0].kind == "Standalone Compo")
        #expect(events[0].when == "1 October - 31 December 2026")
        #expect(events[0].tagline == "There can be only 2! :)")
        #expect(events[0].imageURL != nil)
        #expect(events[1].imageURL == nil)
        #expect(events[1].url.absoluteString == "https://csdb.dk/event/?id=3672")
    }

    @Test func readsNews() {
        let feed = rss("""
        <item><title>Sad left Padua</title><link>https://csdb.dk/scener/?id=1&amp;rss</link></item>
        <item><title>Marzieh entered the scene</title></item>
        """)
        let news = CSDbFeeds.news(from: feed)
        #expect(news.map(\.text) == ["Sad left Padua", "Marzieh entered the scene"])
        #expect(news[0].url?.absoluteString == "https://csdb.dk/scener/?id=1")
        #expect(news[1].url == nil)
    }

    @Test func findsOneScenerInSearchResults() {
        let html = """
        <a href="/scener/?id=7516"><font color="#2575ff">Usul</font></a>
        <b>2 sceners</b> match:<br><ol>
        <li> <a href="/scener/?id=8131">Rob Hubbard</a><br>
        <li> <a href="/scener/?id=999">Rob Hubbard/Fake</a><br>
        <li> <a href="/scener/?id=8645">Chris Huelsbeck</a><br>
        </ol><hr><b>1 event</b> match:<br><ol><li><a href="/event/?id=1">x</a></ol>
        """
        let matches = CSDbScener.searchMatches(in: html)
        #expect(matches.map(\.id) == [8131, 999, 8645])
        // Two sceners go by that name: no guess.
        #expect(CSDbScener.uniqueID(for: ["Rob Hubbard"], in: matches) == nil)
        // CSDb spells Hülsbeck without the umlaut.
        #expect(CSDbScener.uniqueID(for: ["Chris Hülsbeck"], in: matches) == 8645)
        #expect(CSDbScener.uniqueID(for: ["Nobody"], in: matches) == nil)
    }

    @Test func readsAHandle() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Handle><ID>8131</ID><Handle>Rob Hubbard</Handle><AKA>Robb</AKA>
        <Scener><ID>7400</ID><Country>United Kingdom</Country>
        <Trivia>See [url=https://en.wikipedia.org/wiki/Rob_Hubbard]Wikipedia[/url].
        Brother of &lt;scener id="1"&gt;.</Trivia>
        <Handles><Handle><ID>8131</ID></Handle></Handles></Scener>
        <FreelanceFunctions><Function>Coder</Function><Function>Musician</Function></FreelanceFunctions>
        </Handle></CSDbData>
        """.utf8)
        let profile = try #require(CSDbScener.profile(from: xml))
        #expect(profile.id == 8131)
        #expect(profile.name == "Rob Hubbard")
        #expect(profile.aka == "Robb")
        #expect(profile.country == "United Kingdom")
        #expect(profile.roles == ["Coder", "Musician"])
        let trivia = try #require(profile.triviaText())
        #expect(String(trivia.characters) == "See Wikipedia.")
        #expect(trivia.runs.contains { $0.link?.host == "en.wikipedia.org" })
    }

    @Test func readsHandlesGroupsAndNewestCredit() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Handle><ID>20011</ID><Handle>Jan Harries</Handle>
        <CurrentlyUsedHandle>false</CurrentlyUsedHandle>
        <Scener><ID>833</ID><Handles><Handle><ID>20011</ID></Handle>
        <Handle><ID>22684</ID><Handle>SIDWAVE</Handle><CurrentlyUsedHandle>true</CurrentlyUsedHandle><Scener><ID>833</ID></Scener></Handle>
        </Handles></Scener>
        <MemberOf><Group><ID>308</ID><Name>The Supply Team</Name></Group><Status>active</Status></MemberOf>
        <MemberOf><Group><ID>1</ID><Name>Ancients</Name></Group><LeaveYear>1990</LeaveYear><Status>ex</Status></MemberOf>
        <Released><Release><ID>3</ID><Name>Old Tune</Name><Type>C64 Music</Type><ReleaseYear>1990</ReleaseYear></Release></Released>
        <Credits>
        <Credit><CreditType>Music</CreditType><Release><ID>3</ID></Release></Credit>
        <Credit><CreditType>Music</CreditType><Release><ID>4</ID><Name>Jan's Ballad 2 [2SID]</Name><Type>C64 Music</Type>
        <ReleaseDay>5</ReleaseDay><ReleaseMonth>11</ReleaseMonth><ReleaseYear>2026</ReleaseYear></Release></Credit>
        <Credit><CreditType>Music</CreditType><Release><ID>5</ID><Name>Recrack</Name><Type>C64 Music Collection</Type><ReleaseYear>2027</ReleaseYear></Release></Credit>
        <Credit><CreditType>Code</CreditType><Release><ID>6</ID><Name>Not Music</Name><Type>C64 Music</Type><ReleaseYear>2028</ReleaseYear></Release></Credit>
        </Credits></Handle></CSDbData>
        """.utf8)
        let profile = try #require(CSDbScener.profile(from: xml))
        #expect(profile.handles.map(\.name) == ["SIDWAVE", "Jan Harries"])
        #expect(profile.groups == ["The Supply Team"])
        #expect(profile.formerGroups == ["Ancients"])
        #expect(profile.latestMusic?.name == "Jan's Ballad 2 [2SID]")
        #expect(profile.latestMusic?.dateText == "5 Nov 2026")
    }

    @Test func readsTheChartBestFirst() {
        let html = """
        <a href="/release/?id=1">Sidebar</a>
        <b>Release Name</b></td><td><b>Weighted Average</b></td><td width=10></td><td><b>#
        votes</b></td></tr>
        <tr><td align=right>1</td><td><a href="/release/?id=252069">Hypersonic Lovers</a> by <a href="/group/?id=240">Atlantis</a>, <a href="/group/?id=1563">MultiStyle Labs</a></td><td align=center><font size=1>10.00</font></td><td></td><td align=center>19</td></tr>
        <tr><td align=right> </td><td><a href="/release/?id=239260">NTWRK &amp; BRKDWN</a> by <a href="/scener/?id=16"><font color=#2575ff>Someone</font></a></td><td align=center><font size=1>10.00</font></td><td></td><td align=center>25</td></tr>
        <tr><td align=right>3</td><td><a href="/release/?id=3">Lone Tune</a></td><td align=center><font size=1>9.97</font></td><td></td><td align=center>33</td></tr>
        </table><a href="/release/?id=2">Sidebar too</a>
        """
        let chart = CSDbTopList.music(from: html)
        #expect(chart.map(\.id) == [239260, 252069, 3])
        #expect(chart[0].title == "NTWRK & BRKDWN")
        #expect(chart[0].groups == ["Someone"])
        #expect(chart[1].groups == ["Atlantis", "MultiStyle Labs"])
        #expect(chart[2].groups.isEmpty)
        #expect(chart[2].rating == 9.97)
    }

    @Test func readsGroupDetailsAndCompoResults() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Handle><ID>1</ID><Handle>Someone</Handle>
        <MemberOf><Group><ID>308</ID><Name>The Supply Team</Name><Short>TST</Short><FoundMonth>8</FoundMonth><FoundYear>1985</FoundYear></Group><Status>active</Status></MemberOf>
        <Released>
        <Release><ID>10</ID><Name>Winner</Name><Type>C64 Music</Type><ReleaseYear>2024</ReleaseYear>
        <ReleasedAt><Event><ID>7</ID><Name>X'2024</Name></Event></ReleasedAt>
        <Achievement><Compo>C64 Music</Compo><Place>1</Place></Achievement></Release>
        <Release><ID>11</ID><Name>Runner Up</Name><Type>C64 Music</Type><ReleaseYear>2025</ReleaseYear>
        <ReleasedAt><Event><ID>7</ID></Event></ReleasedAt>
        <Achievement><Compo>Mixed Music</Compo><Place>2</Place></Achievement></Release>
        <Release><ID>12</ID><Name>Also Ran</Name><Type>C64 Music</Type><ReleaseYear>2026</ReleaseYear>
        <Achievement><Compo>C64 Music</Compo><Place>12</Place></Achievement></Release>
        <Release><ID>13</ID><Name>A Demo</Name><Type>C64 Demo</Type><ReleaseYear>2026</ReleaseYear>
        <Achievement><Compo>C64 Demo</Compo><Place>1</Place></Achievement></Release>
        </Released></Handle></CSDbData>
        """.utf8)
        let profile = try #require(CSDbScener.profile(from: xml))
        #expect(profile.groups == ["The Supply Team (TST)"])
        #expect(profile.groupFormed == "August 1985")
        #expect(profile.results.map(\.title) == ["Winner", "Runner Up"])
        #expect(profile.results[0].event == "X'2024")
        #expect(profile.results[1].event == "X'2024")
        #expect(profile.results[0].placeText == "1st")
    }

    @Test func readsAGroupForTheNews() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Group><ID>308</ID><Name>The Supply Team</Name><Short>TST</Short>
        <Trivia>Unverified text</Trivia><BaseCountry>Denmark</BaseCountry>
        <FoundMonth>8</FoundMonth><FoundYear>1985</FoundYear>
        <Grouptypes><Grouptype>Swapping Group</Grouptype><Grouptype>Demo Group</Grouptype></Grouptypes>
        </Group></CSDbData>
        """.utf8)
        let detail = try #require(CSDbGroupInfo.detail(from: xml))
        #expect(detail.name == "The Supply Team (TST)")
        #expect(detail.lines == ["Denmark", "Swapping Group, Demo Group", "Formed 1985"])
    }

    @Test func readsAReleasesCoverDateAndPlacing() {
        let placed = CSDbReleaseFiles.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Release><ID>1</ID><ReleaseMonth>4</ReleaseMonth><ReleaseYear>2025</ReleaseYear>
        <ScreenShot>https://csdb.dk/gfx/releases/252000/252069.png</ScreenShot>
        <ReleasedAt><Event><ID>3</ID><Name>Revision 2025</Name></Event></ReleasedAt>
        <Achievement><Compo>Mixed Music</Compo><Place>3</Place></Achievement>
        <UsedSIDs><SID><Author>Michael P. Bridgewater (Mibri)</Author></SID></UsedSIDs>
        </Release></CSDbData>
        """.utf8))
        #expect(placed.cover?.absoluteString == "https://csdb.dk/gfx/releases/252000/252069.png")
        #expect(placed.composerHandle == "Mibri")
        #expect(placed.story == "3rd, Mixed Music at Revision 2025")

        let plain = CSDbReleaseFiles.parse(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Release><ID>1</ID><ReleaseMonth>9</ReleaseMonth><ReleaseYear>2025</ReleaseYear>
        <ScreenShot>https://example.com/elsewhere.png</ScreenShot>
        <UsedSIDs><SID><Author>Rob Hubbard &amp; Simon Nicol</Author></SID></UsedSIDs>
        </Release></CSDbData>
        """.utf8))
        #expect(plain.cover == nil)
        #expect(plain.composerHandle == "Rob Hubbard & Simon Nicol")
        #expect(plain.story == "Released Sep 2025")
        #expect(CSDbReleaseFiles().story == nil)
    }

    @Test func readsAnEventsDaysHoweverTheyreWritten() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
        #expect(CSDbEvent.days(of: "6 - 8 November 2026", calendar: calendar) == day(2026, 11, 6)...day(2026, 11, 8))
        #expect(CSDbEvent.days(of: "1 October - 31 December 2026", calendar: calendar) == day(2026, 10, 1)...day(2026, 12, 31))
        #expect(CSDbEvent.days(of: "30 December 2026 - 2 January 2027", calendar: calendar) == day(2026, 12, 30)...day(2027, 1, 2))
        #expect(CSDbEvent.days(of: "28 November 2026", calendar: calendar) == day(2026, 11, 28)...day(2026, 11, 28))
        #expect(CSDbEvent.days(of: "November 2026", calendar: calendar) == day(2026, 11, 1)...day(2026, 11, 30))
        #expect(CSDbEvent.days(of: "soon", calendar: calendar) == nil)
        #expect(CSDbEvent.days(of: "", calendar: calendar) == nil)
    }

    @Test func featuresTheNewestWhatsOnAndTheBest() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let url = URL(string: "https://csdb.dk")!
        let newest = CSDbRelease(id: 1, title: "New", groups: [], kind: "C64 Music", date: today, url: url, imageURL: nil)
        func event(_ id: Int, _ kind: String, _ when: String) -> CSDbEvent {
            CSDbEvent(id: id, title: "E\(id)", kind: kind, when: when, tagline: nil, url: url, imageURL: nil)
        }
        let compo = event(10, "Standalone Compo", "1 October - 31 December 2026")
        let party = event(11, "Demo Party", "6 - 8 November 2026")
        let later = event(12, "Demo Party", "28 November 2026")
        let best = CSDbTopRelease(id: 2, title: "Best", groups: [], rating: 10, votes: 31)

        #expect(SceneFeature.pick(music: [newest], events: [compo, party, later], top: [best], today: today, calendar: calendar)
            == [.release(newest), .event(party), .top(best)], "a party before a months-long compo")
        #expect(SceneFeature.pick(music: [newest], events: [compo, later], top: [], today: today, calendar: calendar)
            == [.release(newest), .event(compo)])
        #expect(SceneFeature.pick(music: [], events: [later], top: [], today: today, calendar: calendar).isEmpty, "nothing on yet")
        let same = CSDbTopRelease(id: 1, title: "New", groups: [], rating: 10, votes: 31)
        #expect(SceneFeature.pick(music: [newest], events: [], top: [same], today: today, calendar: calendar) == [.release(newest)])
    }

    @Test func theFeaturedHeaderWaitsWhilePaused() {
        var clock = SceneFeatureClock()
        var due = clock.advance(by: 4, isPaused: false)
        #expect(!due)
        #expect(clock.progress == 0.5)
        due = clock.advance(by: 100, isPaused: true)
        #expect(!due, "under the pointer it stays")
        #expect(clock.progress == 0.5, "and keeps its place")
        due = clock.advance(by: 4, isPaused: false)
        #expect(due)
        clock.reset()
        #expect(clock.progress == 0)
    }

    @Test func aFeatureSaysWhatKindItIs() {
        let url = URL(string: "https://csdb.dk")!
        let today = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func release(daysOld: Double) -> SceneFeature {
            .release(CSDbRelease(id: 1, title: "T", groups: [], kind: "C64 Music", date: today.addingTimeInterval(-daysOld * 86400), url: url, imageURL: nil))
        }
        #expect(release(daysOld: 1).typeName(today: today) == "Just Released")
        #expect(release(daysOld: 30).typeName(today: today) == "Newest Music")
        #expect(SceneFeature.top(CSDbTopRelease(id: 2, title: "B", groups: [], rating: 10, votes: 1)).typeName(today: today) == "Highest Rated")
    }

    @Test func aChartsCommonRatingIsSaidOnce() {
        func release(_ rating: Double) -> CSDbTopRelease { CSDbTopRelease(id: 1, title: "T", groups: [], rating: rating, votes: 1) }
        #expect(CSDbTopList.commonRating([release(10), release(10)]) == 10)
        #expect(CSDbTopList.commonRating([release(10), release(9.75)]) == nil)
        #expect(CSDbTopList.commonRating([]) == nil)
        #expect(release(1).sidFormat == nil)
        let tagged = CSDbTopRelease(id: 1, title: "Outerversal [2sid]", groups: [], rating: 10, votes: 1)
        #expect(tagged.sidFormat == "2SID")
        #expect(tagged.displayTitle == "Outerversal")
    }

    @Test func findsWhatAReleaseCanPlay() {
        let both = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Release><ID>1</ID>
        <UsedSIDs><SID><ID>9</ID><HVSCPath>/MUSICIANS/H/Hubbard_Rob/Zoolook.sid</HVSCPath><Name>Zoolook</Name><Author>Rob Hubbard</Author></SID></UsedSIDs>
        <DownloadLinks>
        <DownloadLink><Link>https://csdb.dk/getinternalfile.php/1/Tune by Someone.prg</Link><CounterLink>https://csdb.dk/release/download.php?id=1</CounterLink><Status>Ok</Status></DownloadLink>
        <DownloadLink><Link>https://csdb.dk/getinternalfile.php/2/Broken.sid</Link><CounterLink>https://csdb.dk/release/download.php?id=2</CounterLink><Status>Broken</Status></DownloadLink>
        <DownloadLink><Link>http://csdb.dk/getinternalfile.php/3/Into Oblivion.sid</Link><Status>Ok</Status></DownloadLink>
        </DownloadLinks></Release></CSDbData>
        """.utf8)
        let files = CSDbReleaseFiles.parse(both)
        #expect(files.hvscPath == "/MUSICIANS/H/Hubbard_Rob/Zoolook.sid")
        #expect(files.hvscTitle == "Zoolook")
        #expect(files.hvscAuthor == "Rob Hubbard")
        #expect(files.sidDownload?.absoluteString == "https://csdb.dk/getinternalfile.php/3/Into%20Oblivion.sid")

        let elsewhere = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CSDbData><Release><ID>1</ID><DownloadLinks>
        <DownloadLink><Link>https://example.com/tune.sid</Link><Status>Ok</Status></DownloadLink>
        <DownloadLink><Link>https://csdb.dk/getinternalfile.php/1/Program.prg</Link><Status>Ok</Status></DownloadLink>
        </DownloadLinks></Release></CSDbData>
        """.utf8)
        #expect(CSDbReleaseFiles.parse(elsewhere).sidDownload == nil)

        #expect(CSDbReleaseFiles.isSID(Data("PSID....".utf8)))
        #expect(CSDbReleaseFiles.isSID(Data("RSID....".utf8)))
        #expect(!CSDbReleaseFiles.isSID(Data("<html>".utf8)))
    }

    private func summary(type: String = "standard", description: String, extract: String = "",
                         image: String = "https://upload.wikimedia.org/wikipedia/commons/1/1e/Rob_Hubbard.jpg") -> Data {
        Data("""
        {"type":"\(type)","description":"\(description)","extract":"\(extract)",
         "thumbnail":{"source":"https://thumb.wikimedia.org/thumb.jpg"},"originalimage":{"source":"\(image)"}}
        """.utf8)
    }

    @Test func picksOnlyGameMusicPhotosFromCommons() {
        let good = summary(description: "British composer", extract: "He wrote music for the Commodore 64.")
        #expect(WikimediaPhotos.candidate(fromSummary: good)?.file == "Rob_Hubbard.jpg")
        // The same name, another person.
        #expect(WikimediaPhotos.candidate(fromSummary: summary(description: "English rugby league footballer")) == nil)
        #expect(WikimediaPhotos.candidate(fromSummary: summary(type: "disambiguation", description: "video game")) == nil)
        // On Wikipedia only: usually not free.
        let local = summary(description: "video game composer", image: "https://upload.wikimedia.org/wikipedia/en/1/1e/Local.jpg")
        #expect(WikimediaPhotos.candidate(fromSummary: local) == nil)
    }

    @Test func creditsOnlyFreeLicenses() {
        func metadata(_ license: String) -> Data {
            Data("""
            {"query":{"pages":{"1":{"imageinfo":[{"extmetadata":{
            "Artist":{"value":"<a href=\\"x\\">C64Scener</a>"},"LicenseShortName":{"value":"\(license)"}}}]}}}}
            """.utf8)
        }
        #expect(WikimediaPhotos.credit(fromMetadata: metadata("CC BY-SA 4.0")) == "C64Scener, CC BY-SA 4.0")
        #expect(WikimediaPhotos.credit(fromMetadata: metadata("Public domain")) == "C64Scener, Public domain")
        #expect(WikimediaPhotos.credit(fromMetadata: metadata("Fair use")) == nil)
    }
}
