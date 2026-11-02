import Foundation
import Testing

@testable import SceneItCore

@Test func intervalClampsNegativeDurationsToZero() {
    #expect(Interval(clamping: .seconds(-5)) == .zero)
    #expect(Interval.seconds(-1) == .zero)
    #expect(Interval.hours(-3).duration == .zero)
}

@Test func intervalSubtractionSaturatesAtZero() {
    #expect(Interval.seconds(3) - .seconds(10) == .zero)
    #expect(Interval.minutes(2) - .seconds(30) == .seconds(90))
}

@Test func intervalAdditionAndUnitConveniencesAgree() {
    #expect(Interval.minutes(1) + .seconds(30) == .seconds(90))
    #expect(Interval.hours(1) == .minutes(60))
    #expect(Interval.days(1) == .hours(24))
}

@Test func intervalUnitConveniencesSaturateInsteadOfOverflowing() {
    #expect(Interval.days(Int.max) == .seconds(Int.max))
    #expect(Interval.days(Int.min) == .zero)
}

@Test func intervalOrdersByDuration() {
    #expect(Interval.seconds(1) < .seconds(2))
    #expect(!(Interval.seconds(2) < .seconds(2)))
}

@Test func intervalConvertsToDurationAndTimeInterval() {
    let interval = Interval(clamping: .milliseconds(1500))
    #expect(Duration(interval) == .milliseconds(1500))
    #expect(interval.timeInterval == 1.5)
}

@Test func dateArithmeticWithIntervals() {
    let date = Date(timeIntervalSinceReferenceDate: 1000)
    #expect(date - .seconds(100) == Date(timeIntervalSinceReferenceDate: 900))
    #expect(date + .minutes(1) == Date(timeIntervalSinceReferenceDate: 1060))
}
