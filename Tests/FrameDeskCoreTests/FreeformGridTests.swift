import Foundation
import Testing
@testable import FrameDeskCore

struct FreeformGridTests {
    @Test func asymmetricAndOverlappingZonesSurviveDiskReload() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let zones=[Box(CGRect(x:0,y:0,width:0.61,height:1)),Box(CGRect(x:0.61,y:0.42,width:0.39,height:0.58)),Box(CGRect(x:0.68,y:0,width:0.32,height:0.32))]
        let grid=TileGrid(preset:.freeform,customZones:zones)
        #expect(grid.isValid)
        var file=DesktopTilingFile();file.profiles["desktop"]?.grids["display"]=grid
        let store=DesktopTilingStore(url:directory.appendingPathComponent("desktop-tiling.json"))
        try store.save(file)
        #expect(try store.load()==file)
        let bounds=CGRect(x:-1920,y:1000,width:1920,height:1080)
        #expect(grid.frames(in:bounds).allSatisfy { bounds.contains($0) })
        #expect(grid.zone(at:CGPoint(x:bounds.minX+0.75*bounds.width,y:bounds.minY+0.2*bounds.height),in:bounds)==2)
        let overlap=TileGrid(preset:.freeform,customZones:[Box(CGRect(x:0,y:0,width:1,height:1)),Box(CGRect(x:0.2,y:0.2,width:0.3,height:0.3))])
        #expect(overlap.zone(at:CGPoint(x:0.3,y:0.3),in:CGRect(x:0,y:0,width:1,height:1))==1)
        #expect(overlap.zone(at:CGPoint(x:0.9,y:0.9),in:CGRect(x:0,y:0,width:1,height:1))==0)
    }
    @Test func oldGridsDecodeAndConvertWithoutChangingTheirShape() throws {
        let legacy=Data(#"{"preset":"Focus","columns":2,"rows":2,"focusFraction":0.65}"#.utf8)
        let grid=try JSONDecoder().decode(TileGrid.self,from:legacy)
        #expect(grid.customZones==nil && grid.isValid)
        let converted=grid.asFreeform()
        #expect(converted.preset == .freeform && converted.isValid)
        #expect(converted.zones==grid.zones)
        #expect(converted.asFreeform()==converted)
    }
    @Test func dragMoveResizeDrawAndAlignmentStayWithinCanvas() {
        let original=CGRect(x:0.1,y:0.2,width:0.4,height:0.3)
        for handle in TileEditHandle.allCases {
            for delta in [CGSize(width:-2,height:-2),CGSize(width:2,height:2),CGSize(width:0.13,height:-0.07)] {
                let changed=FreeformGeometry.changing(original,by:delta,handle:handle)
                #expect(FreeformGeometry.valid([Box(changed)]))
            }
        }
        let moved=FreeformGeometry.changing(original,by:CGSize(width:0.2,height:0.1),handle:.move)
        let reverted=FreeformGeometry.changing(moved,by:CGSize(width:-0.2,height:-0.1),handle:.move)
        #expect(abs(reverted.minX-original.minX)<0.000001 && abs(reverted.minY-original.minY)<0.000001)
        let snapped=FreeformGeometry.changing(original,by:CGSize(width:0.009,height:0),handle:.right,peers:[Box(CGRect(x:0.52,y:0,width:0.48,height:1))],tolerance:CGSize(width:0.02,height:0))
        #expect(abs(snapped.maxX-0.52)<0.000001)
        let drawn=FreeformGeometry.drawing(from:CGPoint(x:0.8,y:0.7),to:CGPoint(x:0.2,y:0.1))
        #expect(abs(drawn.width-0.6)<0.000001 && abs(drawn.height-0.6)<0.000001 && drawn.minX==0.2 && drawn.minY==0.1)
        #expect(FreeformGeometry.split(Box(original),vertically:true)?.count==2)
        #expect(FreeformGeometry.split(Box(CGRect(x:0,y:0,width:0.04,height:1)),vertically:true)==nil)
    }
    @Test func invalidFreeformDataCannotReplaceSavedSettings() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=DesktopTilingStore(url:directory.appendingPathComponent("desktop-tiling.json"))
        let original=DesktopTilingFile(); try store.save(original)
        for zones in [[],[Box(CGRect(x:-0.1,y:0,width:0.5,height:1))],[Box(CGRect(x:0,y:0,width:0.001,height:1))],Array(repeating:Box(CGRect(x:0,y:0,width:1,height:1)),count:25)] {
            var next=original;next.profiles["desktop"]?.grids["display"]=TileGrid(preset:.freeform,customZones:zones)
            #expect(throws:TilingError.self) { try store.save(next) }
            #expect(try store.load()==original)
        }
    }
}
