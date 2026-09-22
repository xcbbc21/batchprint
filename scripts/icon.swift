import AppKit
let output = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
 let image = NSImage(size:NSSize(width:size,height:size)); image.lockFocus()
 let rect = NSRect(x:0,y:0,width:size,height:size)
 let inset = rect.insetBy(dx:Double(size)*0.06,dy:Double(size)*0.06)
 let path = NSBezierPath(roundedRect:inset,xRadius:Double(size)*0.2,yRadius:Double(size)*0.2)
 NSColor(calibratedRed:0.05,green:0.57,blue:0.58,alpha:1).setFill(); path.fill()
 if let symbol = NSImage(systemSymbolName:"printer.fill",accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:Double(size)*0.6,weight:.medium)) {
  symbol.isTemplate = false
  let symbolRect = NSRect(x:Double(size)*0.20,y:Double(size)*0.20,width:Double(size)*0.60,height:Double(size)*0.60)
  let tinted = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[.white])) ?? symbol
  tinted.draw(in:symbolRect)
 }
 image.unlockFocus()
 let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap); image.draw(in:rect); NSGraphicsContext.restoreGraphicsState()
 let data = bitmap.representation(using:.png,properties:[:])!
 let name:String
 if size == 1024 { name="icon_512x512@2x.png" } else { name="icon_\(size)x\(size).png" }
 try data.write(to:output.appendingPathComponent(name))
 if [32,64,256,512].contains(size) { try data.write(to:output.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
