import AppKit
import Testing
import FrameDeskCore
@testable import FrameDesk

@MainActor
struct FreeformCanvasTests {
    @Test func nativeCanvasDrawMoveResizeAndEscapeUseRealHandlers() throws {
        _=NSApplication.shared
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:600,height:300),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let view=TileCanvasView();window.contentView=view;view.frame=CGRect(x:0,y:0,width:600,height:300)
        view.align=false
        view.zones=[Box(CGRect(x:0,y:0.5,width:0.5,height:0.5))]
        view.selected=0
        var commits:[[Box]]=[]
        view.onCommit={ commits.append($0) }
        func event(_ kind:NSEvent.EventType,_ x:CGFloat,_ y:CGFloat)->NSEvent {
            NSEvent.mouseEvent(with:kind,location:CGPoint(x:x,y:y),modifierFlags:[],timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        let original=view.zones
        view.mouseDown(with:event(.leftMouseDown,100,220))
        view.mouseDragged(with:event(.leftMouseDragged,160,190))
        view.mouseUp(with:event(.leftMouseUp,160,190))
        #expect(abs(view.zones[0].x-0.1)<0.000001 && abs(view.zones[0].y-0.4)<0.000001)
        #expect(commits.count==1 && commits[0]==original)
        let moved=view.zones
        view.mouseDown(with:event(.leftMouseDown,356,195))
        view.mouseDragged(with:event(.leftMouseDragged,446,195))
        view.mouseUp(with:event(.leftMouseUp,446,195))
        #expect(abs(view.zones[0].width-0.65)<0.000001 && abs(view.zones[0].height-0.5)<0.000001)
        #expect(commits.count==2 && commits[1]==moved)
        view.drawing=true
        view.mouseDown(with:event(.leftMouseDown,480,20))
        view.mouseDragged(with:event(.leftMouseDragged,590,110))
        view.mouseUp(with:event(.leftMouseUp,590,110))
        #expect(view.zones.count==2 && view.selected==1 && FreeformGeometry.valid(view.zones))
        view.drawing=false
        let saved=view.zones
        view.mouseDown(with:event(.leftMouseDown,530,60))
        view.mouseDragged(with:event(.leftMouseDragged,480,60))
        let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:2,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        view.keyDown(with:escape)
        view.mouseUp(with:event(.leftMouseUp,480,60))
        #expect(view.zones==saved && commits.count==3)
        window.close()
    }
}
