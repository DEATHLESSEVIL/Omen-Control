import SwiftUI
import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
#if canImport(OmenCore)
import OmenCore
#endif

struct FanRotor: View {
    let rpm: Int?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NativeFanRotor(rpm:rpm,dark:colorScheme == .dark,reduceMotion:reduceMotion)
            .help("Measured RPM drives the blades at 1/240 speed. The housing and lighting stay fixed.")
    }
}
private struct NativeFanRotor: NSViewRepresentable {
    let rpm: Int?; let dark: Bool; let reduceMotion: Bool
    func makeNSView(context: Context) -> RotorDrawingView { RotorDrawingView() }
    func updateNSView(_ view: RotorDrawingView,context: Context) { view.update(rpm:rpm,dark:dark,reduceMotion:reduceMotion) }
    func sizeThatFits(_ proposal: ProposedViewSize,nsView: RotorDrawingView,context: Context) -> CGSize? {
        CGSize(width:proposal.width ?? 78,height:proposal.height ?? 78)
    }
    static func dismantleNSView(_ view: RotorDrawingView,coordinator: ()) { view.shutdown() }
}
private final class RotorDrawingView: NSView {
    private var clock = RotorClock()
    private var rpm: Int?, dark = false, reduced = false
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width:78,height:78) }
    override init(frame: NSRect) {
        super.init(frame:frame)
        // AppKit owns its backing layer; no custom root or nested animation.
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    func update(rpm: Int?,dark: Bool,reduceMotion: Bool) {
        self.rpm=rpm;self.dark=dark;reduced=reduceMotion
        synchronize();needsDisplay=true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.forEach { NotificationCenter.default.removeObserver($0) };observations=[]
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didBecomeKeyNotification] {
                observations.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                    Task { @MainActor in self?.synchronize() }
                })
            }
            observations.append(NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            })
        }
        synchronize()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties();needsDisplay=true }
    private func synchronize() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor
        let animate = visible && !reduced && FanAnimation.revolutionDuration(rpm:rpm) != nil
        clock.setRPM(animate ? rpm : nil,at:CACurrentMediaTime())
        if animate && timer == nil {
            let t=Timer(timeInterval:1/60,repeats:true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.window?.isVisible != true || self.isHiddenOrHasHiddenAncestor { self.pause();return }
                    self.needsDisplay=true
                }
            }
            timer=t;RunLoop.main.add(t,forMode:.common)
        } else if !animate { timer?.invalidate();timer=nil }
        needsDisplay=true
    }
    private func pause() {
        clock.setRPM(nil,at:CACurrentMediaTime());timer?.invalidate();timer=nil
    }
    func shutdown() {
        pause();observations.forEach { NotificationCenter.default.removeObserver($0) };observations=[]
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let c=NSGraphicsContext.current?.cgContext else { return }
        clock.advance(to:CACurrentMediaTime())
        c.clear(bounds);c.saveGState();c.setAlpha(rpm == nil ? 0.35 : 1)
        FanFrameRenderer.draw(in:c,rect:bounds,angle:clock.angle,dark:dark)
        c.restoreGState()
    }
}

/// Rotating blade alpha with fixed lighting and housing, flattened per frame.
enum FanFrameRenderer {
    static func draw(in c: CGContext,rect: CGRect,angle: Double,dark: Bool) {
        c.interpolationQuality = .high
        if let base=FanArtwork.image(part:"base",dark:dark) { c.draw(base,in:rect) }
        if let blade=FanArtwork.image(part:"blades",dark:dark),
           let m=CGContext(data:nil,width:180,height:180,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
            m.interpolationQuality = .high;m.translateBy(x:90,y:90);m.rotate(by:angle)
            m.draw(blade,in:CGRect(x:-90,y:-90,width:180,height:180))
            if let mask=m.makeImage() {
                c.saveGState();c.clip(to:rect,mask:mask)
                let colors=[CGColor(gray:dark ? 0.43 : 0.55,alpha:1),CGColor(gray:dark ? 0.16 : 0.25,alpha:1),CGColor(gray:dark ? 0.32 : 0.45,alpha:1)] as CFArray
                if let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.55,1]) {
                    c.drawLinearGradient(gradient,start:CGPoint(x:rect.minX,y:rect.maxY),end:CGPoint(x:rect.maxX,y:rect.minY),options:[])
                }
                c.restoreGState()
            }
        }
        if let cover=FanArtwork.image(part:"cover",dark:dark) { c.draw(cover,in:rect) }
    }
    static func exportFramesIfRequested() throws -> Bool {
        guard let i=CommandLine.arguments.firstIndex(of:"--render-fan-frames"),CommandLine.arguments.count>i+1 else { return false }
        let folder=URL(fileURLWithPath:CommandLine.arguments[i+1])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for dark in [false,true] {
            for degrees in [0,5,10,45] {
                guard let c=CGContext(data:nil,width:180,height:180,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                draw(in:c,rect:CGRect(x:0,y:0,width:180,height:180),angle:Double(degrees) * .pi / 180,dark:dark)
                let url=folder.appendingPathComponent("fan-\(dark ? "dark" : "light")-\(degrees).png")
                if let image=c.makeImage(),let d=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) {
                    CGImageDestinationAddImage(d,image,nil);CGImageDestinationFinalize(d)
                }
            }
        }
        print("Rendered fan frames without a WindowServer connection.")
        return true
    }
}
private enum FanArtwork {
    // Prefer optional local layers; source-only builds use the vector fallback.
    private static let images: [String: CGImage] = {
        var result: [String: CGImage] = [:]
        for dark in [false,true] {
            for part in ["base","blades","cover"] {
                let key = "fan-\(part)-\(dark ? "dark" : "light")@2x"
                let url = Bundle.main.resourceURL?.appendingPathComponent("LocalFanArtwork/\(key).png")
                if let url, let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                   let image = CGImageSourceCreateImageAtIndex(source,0,nil) {
                    result[key] = image
                } else { result[key] = original(part: part,dark: dark) }
            }
        }
        return result
    }()
    static func image(part: String,dark: Bool) -> CGImage? { images["fan-\(part)-\(dark ? "dark" : "light")@2x"] }
    private static func original(part: String,dark: Bool) -> CGImage? {
        let size: CGFloat = 180
        guard let c = CGContext(data:nil,width:180,height:180,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let center = CGPoint(x:90,y:90)
        switch part {
        case "base":
            c.setStrokeColor(CGColor(gray:dark ? 0.5 : 0.3,alpha:0.25));c.setLineWidth(4)
            c.strokeEllipse(in:CGRect(x:8,y:8,width:164,height:164))
        case "blades":
            for i in 0..<7 {
                c.saveGState();c.translateBy(x:center.x,y:center.y);c.rotate(by:CGFloat(i)*2*CGFloat.pi/7)
                let p=CGMutablePath();p.move(to:CGPoint(x:0,y:12))
                p.addCurve(to:CGPoint(x:-20,y:64),control1:CGPoint(x:-12,y:26),control2:CGPoint(x:-28,y:52))
                p.addCurve(to:CGPoint(x:12,y:72),control1:CGPoint(x:-8,y:78),control2:CGPoint(x:4,y:78))
                p.addCurve(to:CGPoint(x:18,y:48),control1:CGPoint(x:20,y:68),control2:CGPoint(x:24,y:58))
                p.addCurve(to:CGPoint(x:8,y:12),control1:CGPoint(x:14,y:32),control2:CGPoint(x:12,y:20));p.closeSubpath()
                c.addPath(p);c.setFillColor(CGColor(red:0.08,green:0.63,blue:0.59,alpha:0.9));c.fillPath();c.restoreGState()
            }
        default:
            c.setFillColor(CGColor(gray:dark ? 0.15 : 0.95,alpha:1));c.fillEllipse(in:CGRect(x:67,y:67,width:46,height:46))
            c.setFillColor(CGColor(red:0.1,green:0.65,blue:0.6,alpha:1));c.fillEllipse(in:CGRect(x:size/2-9,y:size/2-9,width:18,height:18))
        }
        return c.makeImage()
    }
}
