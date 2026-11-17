import XCTest
@testable import Pecule

final class FinancialHealthScoreServiceTests: XCTestCase {
    private let service = FinancialHealthScoreService()

    private func component(_ kind: FinancialHealthComponent.Kind, in score: FinancialHealthScore) throws -> FinancialHealthComponent {
        try XCTUnwrap(score.components.first { $0.kind == kind })
    }

    func testEveryComponentScoresLinearlyTowardsItsTargetAndNamesTheLever() throws {
        // Income 2000: savings 10 % (half way), fixed 45 % (between 35 and 70), margin 7.5 % (half way), cushion 1.5 months.
        let score = service.score(FinancialHealthInputs(
            monthlyIncome: 2000,
            fixedCharges: 900,
            remainingToLive: 150,
            savingsRate: 0.10,
            totalBalance: 1800,
            averageMonthlyExpenses: 1200
        ))

        let savings = try component(.savings, in: score)
        XCTAssertEqual(savings.score, 50)
        XCTAssertEqual(savings.leverAmount, 200, "10 % more of 2000")

        let fixed = try component(.fixedCharges, in: score)
        XCTAssertEqual(fixed.score, 71, "45 % sits 25/35 of the way from 70 % back to 35 %")
        XCTAssertEqual(fixed.leverAmount, 200, "cut 10 % of income")

        let margin = try component(.margin, in: score)
        XCTAssertEqual(margin.score, 50)
        XCTAssertEqual(margin.leverAmount, 150)

        let cushion = try component(.cushion, in: score)
        XCTAssertEqual(cushion.score, 50)
        XCTAssertEqual(cushion.leverAmount, 1800, "1.5 more months of 1200")

        // 50 x 0.30 + 71 x 0.25 + 50 x 0.20 + 50 x 0.25 = 55.25, rounded. Kept as a literal: the CI compiler
        // gives up type-checking the mixed-literal expression.
        XCTAssertEqual(score.total, 55)
        XCTAssertEqual(score.grade, .c)
        XCTAssertEqual(score.weakestComponent?.kind, .cushion, "ties resolve alphabetically: cushion before margin before savings")
    }

    func testTargetsReachedGiveAnAWithoutLevers() throws {
        let score = service.score(FinancialHealthInputs(
            monthlyIncome: 2000,
            fixedCharges: 600,
            remainingToLive: 500,
            savingsRate: 0.25,
            totalBalance: 6000,
            averageMonthlyExpenses: 1500
        ))

        XCTAssertEqual(score.total, 100)
        XCTAssertEqual(score.grade, .a)
        XCTAssertTrue(score.components.allSatisfy { $0.leverAmount == nil })
    }

    func testUnmeasuredComponentsAreRenormalisedNotPenalised() throws {
        let noAccount = service.score(FinancialHealthInputs(
            monthlyIncome: 2000,
            fixedCharges: 600,
            remainingToLive: 500,
            savingsRate: 0.25,
            totalBalance: nil,
            averageMonthlyExpenses: 1500
        ))
        XCTAssertNil(try component(.cushion, in: noAccount).score)
        XCTAssertEqual(noAccount.total, 100, "three perfect measured components still make 100")
        XCTAssertNotEqual(noAccount.weakestComponent?.kind, .cushion)

        let noIncome = service.score(FinancialHealthInputs(
            monthlyIncome: 0,
            fixedCharges: 600,
            remainingToLive: -600,
            savingsRate: nil,
            totalBalance: nil,
            averageMonthlyExpenses: 600
        ))
        XCTAssertNil(noIncome.total)
        XCTAssertNil(noIncome.grade)
        XCTAssertNil(noIncome.weakestComponent)
    }

    func testGradeBoundaries() {
        XCTAssertEqual(FinancialHealthScore.Grade(total: 80), .a)
        XCTAssertEqual(FinancialHealthScore.Grade(total: 79), .b)
        XCTAssertEqual(FinancialHealthScore.Grade(total: 65), .b)
        XCTAssertEqual(FinancialHealthScore.Grade(total: 50), .c)
        XCTAssertEqual(FinancialHealthScore.Grade(total: 35), .d)
        XCTAssertEqual(FinancialHealthScore.Grade(total: 34), .e)
    }
}
