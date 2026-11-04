import XCTest

/// `AmbientGate` is the one piece of the ambient-light gate worth testing in isolation: pure
/// logic with an injected clock. The target compiles `AmbientGate.swift` directly rather than
/// loading the app, so these run without a host, Screen Recording, or the sensor.
final class AmbientGateTests: XCTestCase {
    private var gate: AmbientGate!
    private var flips: [Bool] = []
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    override func setUp() {
        super.setUp()
        gate = AmbientGate()
        gate.threshold = 50
        flips = []
        gate.onChange = { [unowned self] dark in self.flips.append(dark) }
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// One reading a second, `lux` from `from` through `through` inclusive.
    private func feed(_ lux: Double?, from: Int, through: Int) {
        for s in from ... through { gate.ingest(lux: lux, at: at(TimeInterval(s))) }
    }

    /// Lux 30 for 0 ... 5 s: dark at t = 5. Flips are cleared so each test counts only its own.
    private func makeDark() {
        feed(30, from: 0, through: 5)
        XCTAssertTrue(gate.isDark)
        flips = []
    }

    func testEnterTooShort() {
        feed(30, from: 0, through: 4)
        XCTAssertFalse(gate.isDark)
        XCTAssertEqual(flips, [])
    }

    func testEnter() {
        feed(30, from: 0, through: 5)
        XCTAssertTrue(gate.isDark)
        XCTAssertEqual(flips, [true])
    }

    func testBounceResetsDwell() {
        feed(30, from: 0, through: 2)
        feed(80, from: 3, through: 3)
        feed(30, from: 4, through: 6)
        XCTAssertFalse(gate.isDark)
        XCTAssertEqual(flips, [])
    }

    func testExitHysteresis() {
        makeDark()
        feed(80, from: 6, through: 66)
        XCTAssertTrue(gate.isDark, "80 lx is below the 100 lx exit level")
        XCTAssertEqual(flips, [])
    }

    func testExit() {
        makeDark()
        feed(150, from: 6, through: 26)
        XCTAssertFalse(gate.isDark)
        XCTAssertEqual(flips, [false])
    }

    func testFlashlight() {
        makeDark()
        feed(2000, from: 6, through: 8)
        feed(10, from: 9, through: 9)
        XCTAssertTrue(gate.isDark)
        XCTAssertEqual(flips, [])
    }

    func testNoReadingHoldsState() {
        makeDark()
        feed(nil, from: 6, through: 606)
        XCTAssertTrue(gate.isDark)
        XCTAssertEqual(flips, [])
    }

    func testThresholdRaisedMidway() {
        gate.threshold = 20
        feed(30, from: 0, through: 3)
        XCTAssertFalse(gate.isDark)
        gate.threshold = 50
        feed(30, from: 4, through: 8)
        XCTAssertFalse(gate.isDark, "dwell starts at the first tick that wants dark")
        feed(30, from: 9, through: 9)
        XCTAssertTrue(gate.isDark)
        XCTAssertEqual(flips, [true])
    }

    func testReset() {
        makeDark()
        gate.reset()
        XCTAssertFalse(gate.isDark)
        XCTAssertNil(gate.pending(at: at(6)))
        XCTAssertEqual(flips, [])
    }

    func testPendingTowardDark() {
        feed(30, from: 0, through: 2)
        let pending = try! XCTUnwrap(gate.pending(at: at(2.5)))
        XCTAssertTrue(pending.towardDark)
        XCTAssertEqual(pending.progress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pending.remaining, 2.5, accuracy: 1e-9)
    }

    func testPendingTowardBright() {
        makeDark()
        feed(150, from: 6, through: 21)
        let pending = try! XCTUnwrap(gate.pending(at: at(21)))
        XCTAssertFalse(pending.towardDark)
        XCTAssertEqual(pending.progress, 0.75, accuracy: 1e-9)
        XCTAssertEqual(pending.remaining, 5, accuracy: 1e-9)
    }

    func testPendingCleared() {
        feed(30, from: 0, through: 2)
        XCTAssertNotNil(gate.pending(at: at(2)))
        feed(80, from: 3, through: 3)
        XCTAssertNil(gate.pending(at: at(3)))
    }

    func testPendingIsPure() {
        feed(30, from: 0, through: 2)
        _ = gate.pending(at: at(100))
        XCTAssertFalse(gate.isDark)
        XCTAssertNotNil(gate.pending(at: at(3)))
    }

    /// The sensor floors at 1 lx, the lowest settable threshold. A reading equal to the
    /// threshold must count as dark, or "enable below 1 lx" could never re-engage after a
    /// bright spell.
    func testThresholdAtSensorFloorReengages() {
        gate.threshold = 1
        gate.exitRatio = 1.2
        feed(1, from: 0, through: 5)
        XCTAssertTrue(gate.isDark, "a reading at the threshold counts as dark")
        feed(5, from: 6, through: 26)
        XCTAssertFalse(gate.isDark)
        feed(1, from: 27, through: 32)
        XCTAssertTrue(gate.isDark, "back at the floor, the gate engages again")
        XCTAssertEqual(flips, [true, false, true])
    }
}
