import XCTest
@testable import HerdrMenubar

final class WidgetTimelinePlanTests: XCTestCase {
    func testDenseExpirationsRetainPublicationAndSourceStaleTransitions() {
        let now = Date(timeIntervalSince1970: 100_000)
        let plan = WidgetTimelinePlan(now: now, writtenAt: now, sourceVerifiedAt: now.addingTimeInterval(-60), messageDates: (1...50).map { now.addingTimeInterval(Double($0) - 3600) }, window: .hours, amount: 1)
        XCTAssertTrue(plan.steps.contains { $0.date == now.addingTimeInterval(180) })
        XCTAssertTrue(plan.steps.contains { $0.date == now.addingTimeInterval(120) })
        XCTAssertTrue(plan.steps.contains { $0.date == now.addingTimeInterval(33) && $0.needsRefresh })
        XCTAssertTrue(plan.steps.filter { $0.date >= now.addingTimeInterval(33) }.allSatisfy(\.needsRefresh))
        XCTAssertLessThanOrEqual(plan.steps.count, 36)
        XCTAssertLessThanOrEqual(plan.reloadAt, now.addingTimeInterval(33))
    }
    func testNormalExpirationsRemainExactAndAllIgnoresMessageDates() {
        let now = Date(timeIntervalSince1970: 100_000)
        let messages = [now.addingTimeInterval(-3590), now.addingTimeInterval(-3500)]
        let plan = WidgetTimelinePlan(now: now, writtenAt: now, messageDates: messages, window: .hours, amount: 1)
        XCTAssertTrue(plan.steps.contains { $0.date == now.addingTimeInterval(10) })
        XCTAssertTrue(plan.steps.contains { $0.date == now.addingTimeInterval(100) })
        XCTAssertFalse(plan.steps.contains(where: \.needsRefresh))
        let all = WidgetTimelinePlan(now: now, writtenAt: now, messageDates: messages, window: .all, amount: 1)
        XCTAssertFalse(all.steps.contains { $0.date == now.addingTimeInterval(10) })
    }
    func testTodayExpiresAtLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_789_342_000)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let plan = WidgetTimelinePlan(now: now, writtenAt: now, messageDates: [], window: .today, amount: 1, calendar: calendar)
        XCTAssertTrue(plan.steps.contains { $0.date == midnight })
    }
}
