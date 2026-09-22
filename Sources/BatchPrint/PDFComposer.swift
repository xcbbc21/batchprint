import Foundation
import PDFKit
import CoreGraphics

enum PDFComposer {
 static func compose(source: URL, destination: URL, settings: OutputSettings) throws -> Int {
  guard let doc = PDFDocument(url: source), !doc.isLocked else { throw PrintFailure("无法读取 PDF，或 PDF 尚未解锁") }
  let indices = try PageSelection.parse(settings.pageRange, count: doc.pageCount)
  var box = CGRect(origin: .zero, size: settings.pageSize)
  guard let consumer = CGDataConsumer(url: destination as CFURL), let output = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PrintFailure("无法创建输出 PDF") }
  defer { output.closePDF() }
  for index in indices {
   try Task.checkCancellation()
   guard let page = doc.page(at: index), let ref = page.pageRef else { throw PrintFailure("无法读取 PDF 页面") }
   output.beginPDFPage(nil)
   if settings.grayscale {
    let scale: CGFloat = 300.0 / 72.0
    guard let raster = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw PrintFailure("无法创建灰度页面") }
    raster.scaleBy(x: scale, y: scale); raster.setFillColor(gray: 1, alpha: 1); raster.fill(box)
    draw(ref, in: raster, box: box, settings: settings)
    guard let image = raster.makeImage() else { throw PrintFailure("灰度页面生成失败") }
    output.draw(image, in: box)
   } else { draw(ref, in: output, box: box, settings: settings) }
   output.endPDFPage()
  }
  return indices.count
 }
 private static func draw(_ page: CGPDFPage, in context: CGContext, box: CGRect, settings: OutputSettings) {
  context.saveGState(); defer { context.restoreGState() }; context.clip(to: box)
  var target = box
  if !settings.fitToPage {
   let source = page.getBoxRect(.cropBox)
   let angle = ((Int(page.rotationAngle) + settings.rotation) % 360 + 360) % 360
   let size = angle == 90 || angle == 270 ? CGSize(width: source.height, height: source.width) : source.size
   target = CGRect(x: (box.width-size.width)/2, y: (box.height-size.height)/2, width: size.width, height: size.height)
  }
  context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: Int32(settings.rotation), preserveAspectRatio: true))
  context.drawPDFPage(page)
 }
}
