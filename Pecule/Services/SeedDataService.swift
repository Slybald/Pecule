import Foundation

struct SeedDataService {
    func makeSeedData() -> AppDataSnapshot {
        AppDataSnapshot(
            subscriptions: subscriptions,
            purchases: purchases,
            goals: goals,
            habits: habits,
            incomeSources: incomeSources,
            monthlyIncomeOverrides: monthlyIncomeOverrides
        )
    }
}

private extension SeedDataService {
    var seedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    func uuid(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("Invalid seed UUID: \(value)")
        }

        return uuid
    }

    func decimal(_ value: String) -> Decimal {
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            preconditionFailure("Invalid seed decimal: \(value)")
        }

        return decimal
    }

    func date(year: Int, month: Int, day: Int) -> Date {
        let components = DateComponents(
            timeZone: seedCalendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )

        guard let date = seedCalendar.date(from: components) else {
            preconditionFailure("Invalid seed date: \(year)-\(month)-\(day)")
        }

        return date
    }

    var subscriptions: [Subscription] {
        [
            Subscription(
                id: uuid("11111111-1111-1111-1111-111111111111"),
                name: "Netflix",
                amount: decimal("15.99"),
                billingCycle: .monthly,
                category: "Streaming",
                nextBillingDate: date(year: 2026, month: 3, day: 20),
                isActive: true
            ),
            Subscription(
                id: uuid("22222222-2222-2222-2222-222222222222"),
                name: "iCloud+",
                amount: decimal("2.99"),
                billingCycle: .monthly,
                category: "Storage",
                nextBillingDate: date(year: 2026, month: 3, day: 18),
                isActive: true
            ),
            Subscription(
                id: uuid("33333333-3333-3333-3333-333333333333"),
                name: "Gym Pass",
                amount: decimal("120.00"),
                billingCycle: .yearly,
                category: "Health",
                nextBillingDate: date(year: 2026, month: 10, day: 1),
                isActive: true
            ),
            Subscription(
                id: uuid("44444444-4444-4444-4444-444444444444"),
                name: "Apple Music",
                amount: decimal("10.99"),
                billingCycle: .monthly,
                category: "Music",
                nextBillingDate: date(year: 2026, month: 3, day: 25),
                isActive: false
            )
        ]
    }

    var purchases: [Purchase] {
        [
            Purchase(
                id: uuid("55555555-5555-5555-5555-555555555555"),
                title: "Coffee Maker",
                amount: decimal("79.90"),
                date: date(year: 2026, month: 3, day: 4),
                category: "Home",
                merchant: "Maison Store",
                notes: "Replaced the old machine."
            ),
            Purchase(
                id: uuid("66666666-6666-6666-6666-666666666666"),
                title: "Running Shoes",
                amount: decimal("129.00"),
                date: date(year: 2026, month: 3, day: 8),
                category: "Fitness",
                merchant: "Sport Center",
                notes: "For weekly training."
            ),
            Purchase(
                id: uuid("77777777-7777-7777-7777-777777777777"),
                title: "Desk Lamp",
                amount: decimal("45.50"),
                date: date(year: 2026, month: 3, day: 11),
                category: "Work",
                merchant: "Office Hub",
                notes: nil
            ),
            Purchase(
                id: uuid("88888888-8888-8888-8888-888888888888"),
                title: "Groceries",
                amount: decimal("62.30"),
                date: date(year: 2026, month: 3, day: 12),
                category: "Food",
                merchant: "Fresh Market",
                notes: "Weekly essentials."
            )
        ]
    }

    var goals: [Goal] {
        [
            Goal(
                id: uuid("99999999-9999-9999-9999-999999999999"),
                title: "Emergency Fund",
                targetAmount: decimal("5000.00"),
                currentAmount: decimal("1250.00"),
                targetDate: date(year: 2026, month: 12, day: 31),
                category: "Security",
                isArchived: false
            ),
            Goal(
                id: uuid("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
                title: "Summer Vacation",
                targetAmount: decimal("1500.00"),
                currentAmount: decimal("450.00"),
                targetDate: date(year: 2026, month: 7, day: 1),
                category: "Travel",
                isArchived: false
            ),
            Goal(
                id: uuid("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
                title: "Next iPhone",
                targetAmount: decimal("1200.00"),
                currentAmount: decimal("300.00"),
                targetDate: date(year: 2026, month: 10, day: 15),
                category: "Tech",
                isArchived: false
            ),
            Goal(
                id: uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
                title: "Course Budget",
                targetAmount: decimal("600.00"),
                currentAmount: decimal("600.00"),
                targetDate: date(year: 2026, month: 2, day: 28),
                category: "Learning",
                isArchived: true
            )
        ]
    }

    var habits: [Habit] {
        [
            Habit(
                id: uuid("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),
                title: "No-spend day",
                frequency: .daily,
                targetCount: 4,
                completedCount: 2,
                linkedGoalID: nil,
                isActive: true
            ),
            Habit(
                id: uuid("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"),
                title: "Transfer to savings",
                frequency: .weekly,
                targetCount: 1,
                completedCount: 1,
                linkedGoalID: uuid("99999999-9999-9999-9999-999999999999"),
                isActive: true
            ),
            Habit(
                id: uuid("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),
                title: "Review subscriptions",
                frequency: .weekly,
                targetCount: 1,
                completedCount: 0,
                linkedGoalID: nil,
                isActive: false
            )
        ]
    }

    var incomeSources: [IncomeSource] {
        [
            IncomeSource(
                id: uuid("12121212-1212-1212-1212-121212121212"),
                name: "Monthly Salary",
                amount: decimal("2400.00"),
                type: .salary,
                startDate: date(year: 2026, month: 1, day: 1),
                endDate: nil,
                isRecurring: true,
                isActive: true
            ),
            IncomeSource(
                id: uuid("13131313-1313-1313-1313-131313131313"),
                name: "CAF Support",
                amount: decimal("220.00"),
                type: .aid,
                startDate: date(year: 2026, month: 1, day: 1),
                endDate: nil,
                isRecurring: true,
                isActive: true
            ),
            IncomeSource(
                id: uuid("14141414-1414-1414-1414-141414141414"),
                name: "Mobility Allowance",
                amount: decimal("90.00"),
                type: .mobility,
                startDate: date(year: 2026, month: 2, day: 1),
                endDate: nil,
                isRecurring: true,
                isActive: true
            )
        ]
    }

    var monthlyIncomeOverrides: [MonthlyIncomeOverride] {
        [
            MonthlyIncomeOverride(
                id: uuid("15151515-1515-1515-1515-151515151515"),
                incomeSourceID: uuid("12121212-1212-1212-1212-121212121212"),
                monthStartDate: date(year: 2026, month: 3, day: 1),
                amount: decimal("250.00"),
                replacesSourceAmount: false
            )
        ]
    }
}
