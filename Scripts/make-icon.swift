import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Native vector rendering of Resources/Branding/OMEN.svg, HP's OMEN diamond.
// SVG coordinates are retained so the lettering remains true cutouts.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
func polygon(_ path: CGMutablePath, _ x: Double, _ y: Double, _ deltas: [(Double, Double)]) {
    var point = CGPoint(x: x, y: y)
    path.move(to: point)
    for (dx, dy) in deltas {
        point.x += dx; point.y += dy; path.addLine(to: point)
    }
    path.closeSubpath()
}
for n in [16,32,64,128,256,512,1024] {
    let c = CGContext(data:nil,width:n,height:n,bitsPerComponent:8,bytesPerRow:0,
                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Transparent canvas, with only the original diamond silhouette visible.
    c.translateBy(x: CGFloat(n) * 0.06, y: CGFloat(n) * 0.94)
    c.scaleBy(x: CGFloat(n) * 0.0088, y: -CGFloat(n) * 0.0088)
    let p = CGMutablePath()
    polygon(p, 50, 0, [(50,50),(-50,50),(-50,-50),(50,-50)])
    p.addEllipse(in: CGRect(x:18.478,y:44.118,width:11.344,height:11.344))
    p.addEllipse(in: CGRect(x:20.379,y:46.019,width:7.542,height:7.542))
    polygon(p, 80.274,44.781,[(-9.677,0),(0,10.51),(1.86,0),(0,-8.65),(5.956,0),(0,8.65),(1.86,0),(0,-10.51)])
    polygon(p, 63.39,44.781,[(-9.678,0),(0,10.51),(9.678,0),(0,-1.86),(-7.817,0),(0,-2.465),(6.086,0),(0,-1.86),(-6.086,0),(0,-2.465),(7.817,0),(0,-1.86)])
    polygon(p, 46.288,44.708,[(-5.256,2.102),(-5.255,-2.102),(0,10.584),(1.86,0),(0,-7.837),(3.395,1.358),(3.395,-1.358),(0,7.837),(1.86,0),(0,-10.584)])
    c.addPath(p); c.clip(using: .evenOdd)
    let colors = [CGColor(red:1,green:85.0/255,blue:225.0/255,alpha:1),
                  CGColor(red:1,green:4.0/255,blue:2.0/255,alpha:1),
                  CGColor(red:1,green:180.0/255,blue:2.0/255,alpha:1),
                  CGColor(red:1,green:180.0/255,blue:2.0/255,alpha:1)] as CFArray
    let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(), colors:colors, locations:[0,0.46078,0.99916,1])!
    c.drawLinearGradient(gradient,start:CGPoint(x:0,y:79.232),end:CGPoint(x:97.998,y:39.421),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    let image=c.makeImage()!
    let out=CGImageDestinationCreateWithURL(root.appendingPathComponent("icon-\(n).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(out,image,nil);CGImageDestinationFinalize(out)
}
