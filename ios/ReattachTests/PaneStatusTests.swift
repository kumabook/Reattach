import Foundation
import Testing
@testable import Reattach

struct PaneStatusTests {
    @Test func onlyRunningAgentsAndUnreadOutputAreShown() throws {
        let json = Data("""
        [{"target":"a:0.0","revision":"1","unread":true,"agent":{"state":"running","since":10}},
         {"target":"a:0.1","revision":"2","unread":true,"agent":{"state":"done","since":20}},
         {"target":"a:0.2","revision":"3","unread":false,"agent":{"state":"done","since":20}},
         {"target":"a:0.3","revision":"4","unread":true},
         {"target":"a:0.4","revision":"5","unread":false,"agent":{"state":"interrupted","since":30}},
         {"target":"a:0.5","revision":"6","unread":false,"agent":{"state":"thinking","since":30}}]
        """.utf8)
        let entries = try JSONDecoder().decode([PaneActivity].self, from: json)
        #expect(entries.map { PaneStatus($0) } == [.running, .unread, .none, .unread, .none, .none])
        #expect([PaneStatus.unread, .running, .none].max() == .running)
    }
}
