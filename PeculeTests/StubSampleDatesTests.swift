import XCTest
@testable import Pecule

// Les échantillons du stub servent de données de démonstration et de base d'assertion pour les
// vues mensuelles. Datés « aujourd'hui moins N jours », ils basculaient dans le mois précédent
// au début du mois : les totaux mensuels tombaient à zéro un jour sur dix, sans qu'aucun test
// ne le voie, puisque la suite ne tourne presque jamais un 1er. Le premier correctif repliait le
// décalage vers l'avant : le salaire, à −12 jours, était alors daté dans le futur du 1er au 12 du
// mois, en tête du tri, et deux tests unitaires échouaient. Le repli se fait désormais vers le 1er
// du mois ; ces tests verrouillent à la fois l'appartenance au mois, l'absence de date future et
// l'ordre relatif, que la première version ne vérifiait pas.
final class StubSampleDatesTests: XCTestCase {
    // Les décalages que StubBankGatewayClient.sampleTransactions emploie, en jours avant aujourd'hui.
    private let offsets = [0, -1, -2, -3, -12]

    // Premier jour du mois à partir duquel tous les décalages tombent sur des jours distincts : le 13
    // pour les décalages actuels (13 − 12 = 1). Avant, les plus anciens se confondent sur le 1er.
    private var firstDayWithDistinctDates: Int { 1 - (offsets.min() ?? 0) }

    private func date(
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0,
        calendar: Calendar = .current
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    // « Futur » au sens de l'app : AppState.bankTransactions(in:) masque une opération dont le jour
    // dépasse celui d'aujourd'hui. On compare donc des jours et non des instants : une date
    // d'échantillon est épinglée à midi UTC (BankGatewayDateParser.parseDay), si bien que
    // `sample <= now` échouerait pour « aujourd'hui » dès que `now` précède midi UTC, soit chaque
    // matin à Paris, sans qu'aucune date ne soit réellement postérieure.
    private func isInTheFuture(_ sample: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: sample) > calendar.startOfDay(for: now)
    }

    func testEverySampleDateStaysInTheMonthOfTheDayItIsGeneratedFor() throws {
        let calendar = Calendar.current
        for month in 1 ... 12 {
            for day in 1 ... 28 {
                let now = try XCTUnwrap(
                    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))
                )
                for offset in offsets {
                    let sample = StubBankGatewayClient.day(offset: offset, now: now)
                    XCTAssertTrue(
                        calendar.isDate(sample, equalTo: now, toGranularity: .month),
                        "décalage \(offset) le \(day)/\(month) sort du mois courant"
                    )
                }
            }
        }
    }

    // Le repli vers l'avant datait le salaire dans le futur : aucun décalage ne doit dépasser aujourd'hui.
    func testNoSampleDateIsEverInTheFuture() throws {
        let calendar = Calendar.current
        for month in 1 ... 12 {
            for day in 1 ... 28 {
                let now = try date(month, day)
                for offset in offsets {
                    let sample = StubBankGatewayClient.day(offset: offset, now: now)
                    XCTAssertFalse(
                        isInTheFuture(sample, now: now, calendar: calendar),
                        "décalage \(offset) le \(day)/\(month) est daté dans le futur"
                    )
                }
            }
        }
    }

    // Plus le décalage est négatif, plus la date est ancienne ou égale : les dates ne se croisent
    // jamais, elles peuvent seulement se confondre sur le 1er du mois.
    func testSampleOrderIsPreservedWhateverTheDayOfTheMonth() throws {
        for month in 1 ... 12 {
            for day in 1 ... 28 {
                let now = try date(month, day)
                let dates = offsets.sorted().map { StubBankGatewayClient.day(offset: $0, now: now) }
                XCTAssertEqual(dates, dates.sorted(), "le \(day)/\(month), l'ordre des décalages n'est pas conservé")
            }
        }
    }

    // Le repli ne doit pas écraser deux échantillons sur la même date quand assez de jours se sont
    // écoulés : leurs montants distincts sont ce que les tests de catégorie et de solde comparent.
    // En deçà (avant le 13 pour les décalages actuels), les plus anciens se confondent sur le 1er du
    // mois : seuls l'ordre et l'absence de date future sont alors exigibles.
    func testDistinctOffsetsStayOnDistinctDays() throws {
        let calendar = Calendar.current
        for day in 1 ... 28 {
            let now = try date(2, day)
            let dates = offsets.map { StubBankGatewayClient.day(offset: $0, now: now) }
            if day >= firstDayWithDistinctDates {
                XCTAssertEqual(Set(dates).count, offsets.count, "le \(day)/02, deux échantillons se superposent")
            } else {
                let chronological = offsets.sorted().map { StubBankGatewayClient.day(offset: $0, now: now) }
                XCTAssertEqual(chronological, chronological.sorted(), "le \(day)/02, l'ordre n'est pas conservé")
                for sample in dates {
                    XCTAssertFalse(isInTheFuture(sample, now: now, calendar: calendar), "le \(day)/02, une date est future")
                }
            }
        }
    }

    // Hors début de mois, le comportement d'origine est conservé : la veille reste la veille.
    func testAwayFromTheMonthStartTheOffsetStaysBackward() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 12)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 8, hour: 12)))
        XCTAssertTrue(
            calendar.isDate(StubBankGatewayClient.day(offset: -12, now: now), inSameDayAs: expected)
        )
    }

    // Près du début de mois, le décalage qui sortirait du mois est ramené au 1er, pas reporté vers l'avant.
    func testNearTheMonthStartTheOffsetFoldsToTheFirstDay() throws {
        let calendar = Calendar.current
        let firstOfOctober = try date(10, 1)
        let secondOfOctober = try date(10, 2)
        let fifthOfOctober = try date(10, 5)

        XCTAssertTrue(
            calendar.isDate(StubBankGatewayClient.day(offset: -12, now: fifthOfOctober), inSameDayAs: firstOfOctober),
            "le 5 octobre, −12 jours donne le 1er octobre et non le 17"
        )
        XCTAssertTrue(
            calendar.isDate(StubBankGatewayClient.day(offset: -3, now: fifthOfOctober), inSameDayAs: secondOfOctober),
            "le 5 octobre, −3 jours reste le 2 octobre"
        )
        for offset in offsets {
            XCTAssertTrue(
                calendar.isDate(StubBankGatewayClient.day(offset: offset, now: firstOfOctober), inSameDayAs: firstOfOctober),
                "le 1er octobre, tout décalage (\(offset)) se replie sur le 1er"
            )
        }
    }

    // Garde de l'échantillon complet, aux jours charnières du repli (1er, 5, 12, 13, 28) : le salaire
    // reste l'opération la plus ancienne et aucune date n'est future. Le 1er, tout se confond sur ce
    // jour : « la plus ancienne » s'entend alors au sens large, aucune opération n'est antérieure au salaire.
    func testTheSalaryIsTheOldestSampleOperationAndNothingIsInTheFuture() throws {
        let calendar = Calendar.current
        for month in 1 ... 12 {
            for day in [1, 5, 12, 13, 28] {
                let now = try date(month, day)
                let sample = StubBankGatewayClient.sampleTransactions(now: now, calendar: calendar)
                let salary = try XCTUnwrap(sample.first { $0.remittanceInformation == ["SALAIRE"] })
                let bookingDates = sample.compactMap(\.bookingDate)

                XCTAssertEqual(bookingDates.count, sample.count, "le \(day)/\(month), une opération n'a pas de date comptable")
                XCTAssertEqual(salary.bookingDate, bookingDates.min(), "le \(day)/\(month), le salaire n'est pas l'opération la plus ancienne")
                for transaction in sample {
                    let reference = transaction.entryReference ?? "?"
                    let booking = try XCTUnwrap(transaction.bookingDate)
                    XCTAssertFalse(
                        isInTheFuture(booking, now: now, calendar: calendar),
                        "le \(day)/\(month), l'opération \(reference) est datée dans le futur"
                    )
                    if let valueDate = transaction.valueDate {
                        XCTAssertLessThanOrEqual(
                            valueDate,
                            booking,
                            "le \(day)/\(month), la date de valeur de \(reference) suit sa date comptable"
                        )
                    }
                }
            }
        }
    }

    // BankGatewayJSON.dayString formate en UTC : sans ancrage à midi, un instant proche de minuit local
    // donnait la veille (le 1er octobre à 00:30 à Paris, « aujourd'hui » était daté du 30 septembre,
    // donc hors du mois). L'échantillon ne doit dépendre ni de l'heure ni du fuseau, tant que celui-ci
    // reste dans la plage que l'épinglage à midi UTC représente (de UTC−11 à UTC+12).
    func testSampleDatesDoNotDependOnTheTimeOfDayNorOnTheTimeZone() throws {
        for identifier in ["UTC", "Europe/Paris", "America/New_York", "Asia/Tokyo", "Pacific/Honolulu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            for month in 1 ... 12 {
                for day in [1, 2, 13, 28] {
                    let atNoon = try date(month, day, calendar: calendar)
                    let expected = offsets.map { StubBankGatewayClient.day(offset: $0, now: atNoon, calendar: calendar) }
                    for (hour, minute) in [(0, 30), (23, 30)] {
                        let now = try date(month, day, hour: hour, minute: minute, calendar: calendar)
                        let dates = offsets.map { StubBankGatewayClient.day(offset: $0, now: now, calendar: calendar) }
                        let context = "\(identifier), \(day)/\(month) à \(hour):\(minute)"

                        XCTAssertEqual(dates, expected, "\(context), l'échantillon dépend de l'heure")
                        for sample in dates {
                            XCTAssertTrue(calendar.isDate(sample, equalTo: now, toGranularity: .month), "\(context), une date sort du mois")
                            XCTAssertFalse(isInTheFuture(sample, now: now, calendar: calendar), "\(context), une date est future")
                        }
                    }
                }
            }
        }
    }
}
