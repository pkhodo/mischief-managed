import Foundation
import CoreGraphics

public enum TileEditHandle: String, CaseIterable, Sendable {
    case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
}

public enum FreeformGeometry {
    public static let minimum = 0.04
    public static let maximumTiles = 24
    public static func valid(_ zones: [Box]) -> Bool {
        (1...maximumTiles).contains(zones.count) && zones.allSatisfy {
            $0.isValid && $0.x >= -0.000001 && $0.y >= -0.000001
            && $0.width >= minimum-0.000001 && $0.height >= minimum-0.000001
            && $0.x+$0.width <= 1.000001 && $0.y+$0.height <= 1.000001
        }
    }
    public static func clamped(_ rect: CGRect) -> CGRect {
        Geometry.clamped(rect, in: CGRect(x: 0, y: 0, width: 1, height: 1), minimum: CGSize(width: minimum, height: minimum))
    }
    public static func drawing(from start: CGPoint, to end: CGPoint) -> CGRect {
        let x1 = min(1,max(0,start.x)), x2 = min(1,max(0,end.x))
        let y1 = min(1,max(0,start.y)), y2 = min(1,max(0,end.y))
        return CGRect(x: min(x1,x2), y: min(y1,y2), width: abs(x2-x1), height: abs(y2-y1))
    }
    public static func changing(_ rect: CGRect, by delta: CGSize, handle: TileEditHandle, peers: [Box] = [], tolerance: CGSize = .zero) -> CGRect {
        guard [delta.width,delta.height].allSatisfy(\.isFinite) else { return rect }
        var result: CGRect
        if handle == .move {
            result = clamped(rect.offsetBy(dx: delta.width, dy: delta.height))
        } else {
            var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
            if [.left,.topLeft,.bottomLeft].contains(handle) { x0 = min(x1-minimum,max(0,x0+delta.width)) }
            if [.right,.topRight,.bottomRight].contains(handle) { x1 = max(x0+minimum,min(1,x1+delta.width)) }
            if [.bottom,.bottomLeft,.bottomRight].contains(handle) { y0 = min(y1-minimum,max(0,y0+delta.height)) }
            if [.top,.topLeft,.topRight].contains(handle) { y1 = max(y0+minimum,min(1,y1+delta.height)) }
            result = CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
        }
        guard tolerance.width > 0 || tolerance.height > 0 else { return result }
        let xs: [CGFloat] = [0,1] + peers.flatMap { [$0.rect.minX,$0.rect.maxX] }
        let ys: [CGFloat] = [0,1] + peers.flatMap { [$0.rect.minY,$0.rect.maxY] }
        func correction(_ edges: [CGFloat], _ targets: [CGFloat], _ limit: CGFloat) -> CGFloat {
            targets.flatMap { target in edges.map { target-$0 } }.filter { abs($0) <= limit }.min { abs($0) < abs($1) } ?? 0
        }
        if handle == .move {
            result.origin.x += correction([result.minX,result.maxX],xs,tolerance.width)
            result.origin.y += correction([result.minY,result.maxY],ys,tolerance.height)
            return clamped(result)
        }
        var x0=result.minX,x1=result.maxX,y0=result.minY,y1=result.maxY
        if [.left,.topLeft,.bottomLeft].contains(handle) { x0 += correction([x0],xs,tolerance.width) }
        if [.right,.topRight,.bottomRight].contains(handle) { x1 += correction([x1],xs,tolerance.width) }
        if [.bottom,.bottomLeft,.bottomRight].contains(handle) { y0 += correction([y0],ys,tolerance.height) }
        if [.top,.topLeft,.topRight].contains(handle) { y1 += correction([y1],ys,tolerance.height) }
        if x1-x0 < minimum { x0=result.minX; x1=result.maxX }
        if y1-y0 < minimum { y0=result.minY; y1=result.maxY }
        return clamped(CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0))
    }
    public static func split(_ box: Box, vertically: Bool) -> [Box]? {
        let r=box.rect
        guard vertically ? r.width >= minimum*2 : r.height >= minimum*2 else { return nil }
        if vertically {
            return [Box(CGRect(x:r.minX,y:r.minY,width:r.width/2,height:r.height)),Box(CGRect(x:r.midX,y:r.minY,width:r.width/2,height:r.height))]
        }
        return [Box(CGRect(x:r.minX,y:r.midY,width:r.width,height:r.height/2)),Box(CGRect(x:r.minX,y:r.minY,width:r.width,height:r.height/2))]
    }
}
