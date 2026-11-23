import CoreGraphics

struct TileSnapSettlement {
    enum Decision: Equatable {
        case wait
        case correct(position: Bool, size: Bool)
        case finish
        case unsettled
    }

    let target: CGRect
    private var lastFrame: CGRect?
    private var unchangedSince: Duration = .zero
    private var corrections = 0
    private var nextCorrectionAt: Duration = .zero

    init(target: CGRect) {
        self.target = target
    }

    mutating func observe(_ frame: CGRect?, elapsed: Duration) -> Decision {
        if frame != lastFrame {
            lastFrame = frame
            unchangedSince = elapsed
        }

        if let frame {
            let unchangedFor = elapsed - unchangedSince
            if unchangedFor >= .milliseconds(100), Self.fillsTile(frame, target) {
                return .finish
            }
            if unchangedFor >= .milliseconds(150) {
                if elapsed >= .seconds(1) { return .finish }
                let size = frame.size != target.size
                let firstCorrection = size ? Duration.milliseconds(250) : .zero
                if corrections < 2, elapsed >= max(nextCorrectionAt, firstCorrection) {
                    corrections += 1
                    unchangedSince = elapsed
                    nextCorrectionAt = elapsed + .milliseconds(300)
                    return .correct(position: frame.minX != target.minX || frame.maxY != target.maxY, size: size)
                }
            }
        }

        return elapsed >= .milliseconds(1500) ? .unsettled : .wait
    }

    static func fillsTile(_ frame: CGRect, _ tile: CGRect) -> Bool {
        abs(frame.minX - tile.minX) <= 1 && abs(frame.maxX - tile.maxX) <= 1
            && abs(frame.minY - tile.minY) <= 1 && abs(frame.maxY - tile.maxY) <= 1
    }
}
