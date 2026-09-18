// 从与 RuneMark 相同的几何语言生成 1024px 不透明 App Icon，不依赖显示器的 Retina 倍率。
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(srgbRed: 0.19, green: 0.30, blue: 0.24, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.setStrokeColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.86, alpha: 1))
context.setLineWidth(44); context.setLineCap(.round); context.setLineJoin(.round)
context.move(to: CGPoint(x: 355, y: 220))
context.addLine(to: CGPoint(x: 355, y: 804))
context.addLine(to: CGPoint(x: 693, y: 620))
context.addLine(to: CGPoint(x: 355, y: 445))
context.addLine(to: CGPoint(x: 693, y: 220))
context.strokePath()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
