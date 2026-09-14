import Foundation

struct WidgetTimelinePlan {
    struct Step: Equatable {
        let date: Date
        var needsRefresh = false
    }
    let steps: [Step]
    let reloadAt: Date

    init(now: Date, writtenAt: Date?, sourceVerifiedAt: Date? = nil, messageDates: [Date], window: AgentWindow, amount: Int, calendar: Calendar = .current) {
        var mandatory = [now.addingTimeInterval(180)]
        if let writtenAt { mandatory.append(writtenAt.addingTimeInterval(180)) }
        if let sourceVerifiedAt { mandatory.append(sourceVerifiedAt.addingTimeInterval(180)) }
        var expirations: [Date] = []
        if window == .hours || window == .days {
            let interval = Double(max(1, min(amount, 8760))) * (window == .days ? 86400 : 3600)
            expirations = Array(Set(messageDates.filter { $0 <= now }.map { $0.addingTimeInterval(interval) }.filter { $0 > now })).sorted()
        } else if window == .today, let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            mandatory.append(midnight)
        }
        // Never spend the freshness budget on filter expirations. When exact
        // expiration entries run out, stop presenting eligibility as current.
        let horizon = expirations.count > 32 ? expirations[32] : nil
        var dates = mandatory + Array(expirations.prefix(32))
        if let horizon { dates.append(horizon) }
        steps = [Step(date: now)] + Array(Set(dates.filter { $0 > now })).sorted().map { date in
            Step(date: date, needsRefresh: horizon.map { date >= $0 } ?? false)
        }
        reloadAt = min(now.addingTimeInterval(300), horizon ?? .distantFuture)
    }
}
