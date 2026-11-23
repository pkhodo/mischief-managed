import CoreGraphics
import Testing
@testable import FrameDesk

struct TileSnapSettlementTests {
    private let target = CGRect(x: 1077, y: 1422, width: 1053, height: 708)

    @Test func changingFrameIsNeitherRetriedNorSaved() {
        var snap = TileSnapSettlement(target: target)
        for tick in 0...15 {
            let intermediate = target.insetBy(dx: 0, dy: -CGFloat(17 - tick))
            #expect(snap.observe(intermediate, elapsed: .milliseconds(50 * tick)) == .wait)
        }
        #expect(snap.observe(target, elapsed: .milliseconds(800)) == .wait)
        #expect(snap.observe(target, elapsed: .milliseconds(900)) == .finish)
    }

    @Test func aMomentaryFitDoesNotGetSavedAfterTheAppChangesIt() {
        var snap = TileSnapSettlement(target: target)
        let resized = CGRect(x: target.minX, y: target.minY - 10, width: target.width, height: target.height + 10)
        #expect(snap.observe(target, elapsed: .zero) == .wait)
        #expect(snap.observe(resized, elapsed: .milliseconds(50)) == .wait)
        #expect(snap.observe(resized, elapsed: .milliseconds(200)) == .wait)
        #expect(snap.observe(resized, elapsed: .milliseconds(250)) == .correct(position: false, size: true))
        #expect(snap.observe(target, elapsed: .milliseconds(300)) == .wait)
        #expect(snap.observe(target, elapsed: .milliseconds(400)) == .finish)
    }

    @Test func constrainedWindowStopsAfterTwoPositionCorrections() {
        var snap = TileSnapSettlement(target: target)
        let displaced = target.offsetBy(dx: 4, dy: 0)
        #expect(snap.observe(displaced, elapsed: .zero) == .wait)
        #expect(snap.observe(displaced, elapsed: .milliseconds(150)) == .correct(position: true, size: false))
        #expect(snap.observe(displaced, elapsed: .milliseconds(300)) == .wait)
        #expect(snap.observe(displaced, elapsed: .milliseconds(450)) == .correct(position: true, size: false))
        #expect(snap.observe(displaced, elapsed: .milliseconds(600)) == .wait)
        #expect(snap.observe(displaced, elapsed: .seconds(1)) == .finish)
        #expect(!TileSnapSettlement.fillsTile(displaced, target))
    }

    @Test func continuouslyChangingOrMissingWindowDoesNotSave() {
        var snap = TileSnapSettlement(target: target)
        #expect(snap.observe(target, elapsed: .milliseconds(1400)) == .wait)
        #expect(snap.observe(nil, elapsed: .milliseconds(1450)) == .wait)
        #expect(snap.observe(nil, elapsed: .milliseconds(1500)) == .unsettled)
    }
}
