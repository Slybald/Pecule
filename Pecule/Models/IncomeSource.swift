import Foundation
import SwiftData

enum IncomeType: String, Codable, Hashable, CaseIterable {
    case salary
    case aid
    case bonus
    case mobility
    case other

    var sortOrder: Int {
        switch self {
        case .salary:
            return 0
        case .aid:
            return 1
        case .bonus:
            return 2
        case .mobility:
            return 3
        case .other:
            return 4
        }
    }

    func displayName(locale: Locale = LocalizationManager.currentAppLocale) -> String {
        let localizedValue = AppLocalizer.string(localizationKey, locale: locale)
        return localizedValue == localizationKey ? fallbackDisplayName : localizedValue
    }

    private var localizationKey: String {
        switch self {
        case .salary:
            return "income.type.salary"
        case .aid:
            return "income.type.aid"
        case .bonus:
            return "income.type.bonus"
        case .mobility:
            return "income.type.mobility"
        case .other:
            return "income.type.other"
        }
    }

    private var fallbackDisplayName: String {
        switch self {
        case .salary:
            return "Salary"
        case .aid:
            return "Aid"
        case .bonus:
            return "Bonus"
        case .mobility:
            return "Mobility"
        case .other:
            return "Other"
        }
    }
}

@Model
final class IncomeSource: Identifiable {
    var id: UUID
    var name: String
    var amount: Decimal
    var type: IncomeType
    var startDate: Date
    var endDate: Date?
    var isRecurring: Bool
    var isActive: Bool

    init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        type: IncomeType,
        startDate: Date,
        endDate: Date? = nil,
        isRecurring: Bool,
        isActive: Bool
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
        self.isRecurring = isRecurring
        self.isActive = isActive
    }

    // Les dates de début et de fin sont choisies, et affichées, en heure locale : on les compare en mois
    // civils du calendrier fourni, comme le reste du calcul du mois. Les lire en UTC (m091) faisait commencer
    // en septembre un revenu du 1er octobre saisi à 00:30 à Paris, et finir en novembre un revenu du
    // 31 octobre saisi à 20:00 à New York.
    func applies(toMonthContaining date: Date, calendar: Calendar = .current) -> Bool {
        guard isActive else {
            return false
        }

        let targetMonth = calendar.peculeCalendarMonthStart(containing: date)
        let startMonth = calendar.peculeCalendarMonthStart(containing: startDate)

        guard targetMonth >= startMonth else {
            return false
        }

        if !isRecurring {
            return targetMonth == startMonth
        }

        guard let endDate else {
            return true
        }

        let endMonth = max(calendar.peculeCalendarMonthStart(containing: endDate), startMonth)
        return targetMonth <= endMonth
    }
}

extension Calendar {
    /// Début du mois civil de `date` dans CE calendrier, donc dans son fuseau : la définition du mois pour
    /// comparer des dates et rattacher revenus, plafonds et dépenses au même mois.
    func peculeCalendarMonthStart(containing date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
    }

    /// Ancrage de stockage seulement : midi UTC le 1er du mois UTC de `date`. Les valeurs déjà enregistrées
    /// (surcharges de revenu) restent dans le bon mois local de UTC-12 à UTC+14. Ne pas s'en servir pour
    /// comparer des dates : près d'une borne de mois, le mois UTC n'est pas celui que l'utilisateur voit.
    func peculeMonthStart(for date: Date) -> Date {
        var monthCalendar = self
        monthCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? timeZone

        let components = monthCalendar.dateComponents([.year, .month], from: date)

        return monthCalendar.date(
            from: DateComponents(
                timeZone: monthCalendar.timeZone,
                year: components.year,
                month: components.month,
                day: 1,
                hour: 12
            )
        ) ?? startOfDay(for: date)
    }
}
