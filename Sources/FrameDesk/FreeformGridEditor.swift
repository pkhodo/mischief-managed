import SwiftUI
import AppKit
import FrameDeskCore

struct FreeformGridEditor: View {
    let initial: TileGrid
    let aspect: CGFloat
    let onSave: (TileGrid) -> Bool
    let onCancel: () -> Void
    @ViewState private var zones: [Box]
    @ViewState private var selected = 0
    @ViewState private var drawing = false
    @ViewState private var align = true
    @ViewState private var past: [[Box]] = []
    @ViewState private var future: [[Box]] = []
    @ViewState private var message = ""
    init(grid: TileGrid, aspect: CGFloat, onSave: @escaping (TileGrid) -> Bool, onCancel: @escaping () -> Void) {
        initial=grid;self.aspect=aspect;self.onSave=onSave;self.onCancel=onCancel
        _zones=ViewState(initialValue:grid.zones)
    }
    private var validSelection: Bool { zones.indices.contains(selected) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                controls.padding(24)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit tiles").font(.headline)
                Spacer()
                Button("Undo edit") { undoEdit() }.disabled(past.isEmpty)
                Button("Redo edit") { redoEdit() }.disabled(future.isEmpty)
            }
            Text("Drag a tile to move it. Drag an edge or corner to resize it. Choose Draw tile to draw a new rectangle.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Toggle("Draw tile",isOn:$drawing).toggleStyle(.button)
                Button("Add tile") { add() }.disabled(zones.count>=FreeformGeometry.maximumTiles)
                Button("Delete tile") { remove() }.disabled(!validSelection)
                Spacer()
                Toggle("Snap edges",isOn:$align)
            }
            FreeformCanvas(zones:$zones,selected:$selected,drawing:$drawing,align:align,onCommit:remember,onMessage:{ message=$0 })
                .aspectRatio(aspect,contentMode:.fit)
                .frame(maxWidth:.infinity)
                .accessibilityLabel("Editable desktop tile canvas")
            HStack {
                Picker("Selected tile",selection:$selected) {
                    Text("None").tag(-1)
                    ForEach(zones.indices,id:\.self) { Text("Tile \($0+1)").tag($0) }
                }.frame(maxWidth:220)
                Spacer()
                Button("Split vertically") { split(true) }.disabled(!canSplit(true))
                Button("Split horizontally") { split(false) }.disabled(!canSplit(false))
            }
            HStack(spacing:12) {
                percent("X",key:0);percent("Y",key:1);percent("Width",key:2);percent("Height",key:3)
            }.disabled(!validSelection)
            Text("Percentages use the display’s top-left corner. Tiles can overlap; the smallest tile under the pointer wins.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Clear canvas") { change([]);selected = -1 }.disabled(zones.isEmpty)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save grid") {
                    var result=initial;result.preset = .freeform;result.customZones=zones
                    if !onSave(result) { message="Could not save this grid. Reconnect the original display setup or cancel and edit the current setup." }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s",modifiers:.command).disabled(!FreeformGeometry.valid(zones))
            }
        }
    }
    private func remember(_ before: [Box]) {
        guard before != zones else { return }
        past.append(before);if past.count>50 { past.removeFirst() };future=[];message=""
    }
    private func change(_ next: [Box]) { let before=zones;zones=next;remember(before) }
    private func undoEdit() { guard let next=past.popLast() else { return };future.append(zones);zones=next;selected=min(selected,zones.count-1);message="" }
    private func redoEdit() { guard let next=future.popLast() else { return };past.append(zones);zones=next;selected=min(selected,zones.count-1);message="" }
    private func add() {
        guard zones.count<FreeformGeometry.maximumTiles else { return }
        change(zones+[Box(CGRect(x:0.1,y:0.1,width:0.3,height:0.3))]);selected=zones.count-1;drawing=false
    }
    private func remove() { guard validSelection else { return };var next=zones;next.remove(at:selected);change(next);selected=min(selected,zones.count-1) }
    private func canSplit(_ vertical: Bool) -> Bool { validSelection && zones.count<FreeformGeometry.maximumTiles && FreeformGeometry.split(zones[selected],vertically:vertical) != nil }
    private func split(_ vertical: Bool) {
        guard canSplit(vertical),let pair=FreeformGeometry.split(zones[selected],vertically:vertical) else { return }
        var next=zones;next.replaceSubrange(selected...selected,with:pair);change(next)
    }
    private func percent(_ label: String,key: Int) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text("\(label) %").font(.caption).foregroundStyle(.secondary)
            TextField(label,value:Binding(get:{ value(key) },set:{ update(key,$0) }),format:.number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).accessibilityLabel("Selected tile \(label), percent")
        }
    }
    private func value(_ key: Int) -> Double {
        guard validSelection else { return 0 };let r=zones[selected]
        return [r.x,1-r.y-r.height,r.width,r.height][key]*100
    }
    private func update(_ key: Int,_ percentage: Double) {
        guard validSelection,percentage.isFinite else { return }
        var r=zones[selected].rect;let value=percentage/100
        switch key {
        case 0:r.origin.x=min(max(0,value),1-r.width)
        case 1:r.origin.y=1-r.height-min(max(0,value),1-r.height)
        case 2:r.size.width=min(max(FreeformGeometry.minimum,value),1-r.minX)
        default:
            let top=r.maxY;r.size.height=min(max(FreeformGeometry.minimum,value),top);r.origin.y=top-r.height
        }
        var next=zones;next[selected]=Box(r);change(next)
    }
}

struct FreeformCanvas: NSViewRepresentable {
    @Binding var zones: [Box]
    @Binding var selected: Int
    @Binding var drawing: Bool
    let align: Bool
    let onCommit: ([Box]) -> Void
    let onMessage: (String) -> Void
    func makeNSView(context:Context) -> TileCanvasView { TileCanvasView() }
    func updateNSView(_ view:TileCanvasView,context:Context) {
        view.zones=zones;view.selected=selected;view.drawing=drawing;view.align=align
        view.onZones={ zones=$0 };view.onSelected={ selected=$0 };view.onCommit=onCommit;view.onMessage=onMessage
        view.needsDisplay=true;view.window?.invalidateCursorRects(for:view)
    }
}

final class TileCanvasView: NSView {
    var zones:[Box]=[]
    var selected = -1
    var drawing=false
    var align=true
    var onZones:(([Box])->Void)?
    var onSelected:((Int)->Void)?
    var onCommit:(([Box])->Void)?
    var onMessage:((String)->Void)?
    private var before:[Box]?
    private var start=CGPoint.zero
    private var handle:TileEditHandle?
    private var drawingRect:CGRect?
    override var acceptsFirstResponder:Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityElement(true);setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Tile canvas. Select a tile using the Selected tile control, then edit its percentage fields for keyboard access.")
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func rect(_ box:Box)->CGRect { Geometry.expanded(box,in:bounds) }
    private func unit(_ point:CGPoint)->CGPoint { CGPoint(x:(point.x-bounds.minX)/max(1,bounds.width),y:(point.y-bounds.minY)/max(1,bounds.height)) }
    private func handles(_ r:CGRect)->[(TileEditHandle,CGPoint)] {
        [(.topLeft,CGPoint(x:r.minX,y:r.maxY)),(.top,CGPoint(x:r.midX,y:r.maxY)),(.topRight,CGPoint(x:r.maxX,y:r.maxY)),(.right,CGPoint(x:r.maxX,y:r.midY)),(.bottomRight,CGPoint(x:r.maxX,y:r.minY)),(.bottom,CGPoint(x:r.midX,y:r.minY)),(.bottomLeft,CGPoint(x:r.minX,y:r.minY)),(.left,CGPoint(x:r.minX,y:r.midY))]
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlBackgroundColor.setFill();NSBezierPath(rect:bounds).fill()
        for (index,zone) in zones.enumerated() {
            let r=rect(zone).insetBy(dx:1,dy:1)
            NSColor.controlAccentColor.withAlphaComponent(index==selected ? 0.18 : 0.06).setFill();NSBezierPath(rect:r).fill()
            (index==selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setStroke()
            let path=NSBezierPath(rect:r);path.lineWidth=index==selected ? 2 : 1;path.stroke()
            let text="\(index+1)" as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:15,weight:.semibold),.foregroundColor:NSColor.labelColor]
            let size=text.size(withAttributes:attrs)
            text.draw(at:CGPoint(x:r.midX-size.width/2,y:r.midY-size.height/2),withAttributes:attrs)
        }
        if zones.indices.contains(selected) {
            for (_,point) in handles(rect(zones[selected]).insetBy(dx:4,dy:4)) {
                let circle=NSBezierPath(ovalIn:CGRect(x:point.x-4,y:point.y-4,width:8,height:8))
                NSColor.windowBackgroundColor.setFill();circle.fill();NSColor.controlAccentColor.setStroke();circle.lineWidth=1.5;circle.stroke()
            }
        }
        if let drawingRect {
            let r=CGRect(x:drawingRect.minX*bounds.width,y:drawingRect.minY*bounds.height,width:drawingRect.width*bounds.width,height:drawingRect.height*bounds.height)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill();NSBezierPath(rect:r).fill()
            NSColor.controlAccentColor.setStroke();let path=NSBezierPath(rect:r);path.lineWidth=2;path.setLineDash([5,3],count:2,phase:0);path.stroke()
        }
        NSColor.separatorColor.setStroke();NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5)).stroke()
    }
    override func resetCursorRects() {
        addCursorRect(bounds,cursor:drawing ? .crosshair : .arrow)
        guard !drawing else { return }
        for zone in zones { addCursorRect(rect(zone).insetBy(dx:8,dy:8),cursor:.openHand) }
        if zones.indices.contains(selected) {
            for (kind,point) in handles(rect(zones[selected]).insetBy(dx:4,dy:4)) {
                let cursor:NSCursor = [.left,.right].contains(kind) ? .resizeLeftRight : [.top,.bottom].contains(kind) ? .resizeUpDown : .crosshair
                addCursorRect(CGRect(x:point.x-7,y:point.y-7,width:14,height:14),cursor:cursor)
            }
        }
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let point=convert(event.locationInWindow,from:nil);start=unit(point);before=zones;handle=nil
        if drawing {
            guard zones.count<FreeformGeometry.maximumTiles else { before=nil;onMessage?("A grid can contain up to 24 tiles.");return }
            drawingRect=CGRect(origin:start,size:.zero);needsDisplay=true;return
        }
        if zones.indices.contains(selected),let hit=handles(rect(zones[selected]).insetBy(dx:4,dy:4)).first(where:{ hypot($0.1.x-point.x,$0.1.y-point.y)<=9 }) { handle=hit.0;return }
        let candidate=zones.indices.filter { rect(zones[$0]).contains(point) }.min { a,b in zones[a].width*zones[a].height < zones[b].width*zones[b].height }
        selected=candidate ?? -1;onSelected?(selected)
        if candidate != nil { handle = .move;NSCursor.closedHand.set() }
        needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        guard let before else { return }
        let current=unit(convert(event.locationInWindow,from:nil))
        if drawingRect != nil { drawingRect=FreeformGeometry.drawing(from:start,to:current);needsDisplay=true;return }
        guard before.indices.contains(selected),let handle else { return }
        let tolerance=align ? CGSize(width:7/max(1,bounds.width),height:7/max(1,bounds.height)) : .zero
        let changed=FreeformGeometry.changing(before[selected].rect,by:CGSize(width:current.x-start.x,height:current.y-start.y),handle:handle,peers:before.enumerated().filter { $0.offset != selected }.map(\.element),tolerance:tolerance)
        var next=before;next[selected]=Box(changed);zones=next;onZones?(next);needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        guard let before else { return }
        if let drawingRect {
            if drawingRect.width>=FreeformGeometry.minimum && drawingRect.height>=FreeformGeometry.minimum {
                zones=before+[Box(drawingRect)];selected=zones.count-1;onZones?(zones);onSelected?(selected)
            } else { onMessage?("Draw a larger tile. Minimum width and height are 4% of the display.") }
        }
        drawingRect=nil;self.before=nil;handle=nil;onCommit?(before);needsDisplay=true;window?.invalidateCursorRects(for:self)
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==53 {
            if let before { zones=before;onZones?(before) }
            before=nil;drawingRect=nil;handle=nil;needsDisplay=true;return
        }
        guard zones.indices.contains(selected) else { super.keyDown(with:event);return }
        let step:CGFloat=event.modifierFlags.contains(.shift) ? 0.001 : 0.01
        let delta:CGSize
        switch event.keyCode {
        case 123:delta=CGSize(width:-step,height:0)
        case 124:delta=CGSize(width:step,height:0)
        case 125:delta=CGSize(width:0,height:-step)
        case 126:delta=CGSize(width:0,height:step)
        default:super.keyDown(with:event);return
        }
        let old=zones;zones[selected]=Box(FreeformGeometry.changing(zones[selected].rect,by:delta,handle:.move));onZones?(zones);onCommit?(old);needsDisplay=true
    }
}
