import XCTest
@testable import FaceCore

/// When FaceID asks the keychain by itself after an update. Plain values only: no keychain, no prompt.
final class KeychainPromptPlanTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A tick `at` seconds after `start`, the last input `input` and the last key press `key` seconds before it.
    private func facts(at: TimeInterval, input: TimeInterval = 1_000, key: TimeInterval = 1_000, locked: Bool = false,
                       busy: Bool = false, needed: Bool = true) -> KeychainPromptPlan.Facts {
        .init(now: start.addingTimeInterval(at), needsConfirmation: needed, locked: locked, busy: busy,
              secondsSinceInput: input, secondsSinceKeyPress: key)
    }

    private func waiting() -> KeychainPromptPlan {
        var plan = KeychainPromptPlan()
        plan.wait(since: start)
        return plan
    }

    func testDoesNothingUntilAskedToWait() {
        var plan = KeychainPromptPlan()
        XCTAssertEqual(plan.step(facts(at: 5, input: 0.1)), .stop)
        XCTAssertFalse(plan.asked)
    }

    func testAsksAtTheFirstTouchAfterLaunch() {
        var plan = waiting()
        // Nobody at the Mac: the last input was before FaceID started.
        XCTAssertEqual(plan.step(facts(at: 30, input: 40)), .wait)
        XCTAssertEqual(plan.step(facts(at: 600, input: 610)), .wait)
        // The mouse moves.
        XCTAssertEqual(plan.step(facts(at: 601, input: 0.2)), .ask)
        XCTAssertTrue(plan.asked)
    }

    func testInputRightBeforeTheStartDoesNotCount() {
        var plan = waiting()
        XCTAssertEqual(plan.step(facts(at: 0.5, input: 0.6)), .wait)
        XCTAssertEqual(plan.step(facts(at: 0.5, input: 0.5)), .wait)
    }

    func testWaitsWhileTheUserTypes() {
        var plan = waiting()
        // The key that counts as the touch is still going down: the prompt's password field would catch the next ones.
        XCTAssertEqual(plan.step(facts(at: 10, input: 0.1, key: 0.1)), .wait)
        XCTAssertEqual(plan.step(facts(at: 10.5, input: 0.3, key: 0.6)), .wait)
        XCTAssertEqual(plan.step(facts(at: 11.5, input: 0.4, key: 1.6)), .ask)
    }

    func testNeverOnTheLockScreen() {
        var plan = waiting()
        XCTAssertEqual(plan.step(facts(at: 10, input: 0.1, locked: true)), .wait)
        XCTAssertEqual(plan.step(facts(at: 11, input: 0.1, locked: true)), .wait)
        XCTAssertFalse(plan.asked)
    }

    func testTheUnlockItselfDoesNotBringThePrompt() {
        var plan = waiting()
        XCTAssertEqual(plan.step(facts(at: 100, input: 0.1, key: 2, locked: true)), .wait)
        // Unlocked: the password and Return were typed a moment ago, and the mouse is moving.
        XCTAssertEqual(plan.step(facts(at: 110, input: 0.1, key: 1.2)), .wait)
        XCTAssertEqual(plan.since, start.addingTimeInterval(110 + KeychainPromptPlan.afterUnlock))
        XCTAssertEqual(plan.step(facts(at: 112, input: 0.1, key: 3)), .wait)
        // A few seconds later someone touches the Mac again.
        XCTAssertEqual(plan.step(facts(at: 114, input: 0.1, key: 5)), .ask)
    }

    func testWaitsWhileFaceIDIsBusy() {
        var plan = waiting()
        XCTAssertEqual(plan.step(facts(at: 10, input: 0.1, busy: true)), .wait)
        XCTAssertEqual(plan.step(facts(at: 20, input: 0.1, busy: true)), .wait)
        XCTAssertEqual(plan.step(facts(at: 21, input: 0.1)), .ask)
    }

    func testAsksOnlyOncePerLaunch() {
        var plan = waiting()
        XCTAssertEqual(plan.step(facts(at: 10, input: 0.1)), .ask)
        // Denied, or "Allow" pressed: the island's keychain page takes over, the plan never asks again.
        XCTAssertEqual(plan.step(facts(at: 20, input: 0.1)), .stop)
        plan.wait(since: start.addingTimeInterval(30))
        XCTAssertNil(plan.since)
        XCTAssertEqual(plan.step(facts(at: 40, input: 0.1)), .stop)
    }

    func testStopsWhenConfirmedMeanwhile() {
        var plan = waiting()
        // Confirmed from the island's page before anyone touched the Mac again.
        XCTAssertEqual(plan.step(facts(at: 10, input: 0.1, needed: false)), .stop)
        XCTAssertNil(plan.since)
        XCTAssertFalse(plan.asked)
        // Needed again later in the same launch (refused on the lock screen): waits anew.
        plan.wait(since: start.addingTimeInterval(50))
        XCTAssertEqual(plan.step(facts(at: 51, input: 2)), .wait)
        XCTAssertEqual(plan.step(facts(at: 52, input: 0.5)), .ask)
    }

    func testALaterStartWins() {
        var plan = waiting()
        plan.wait(since: start.addingTimeInterval(20))
        plan.wait(since: start.addingTimeInterval(5))
        XCTAssertEqual(plan.since, start.addingTimeInterval(20))
        XCTAssertEqual(plan.step(facts(at: 21, input: 2)), .wait)
        XCTAssertEqual(plan.step(facts(at: 22, input: 1)), .ask)
    }
}
