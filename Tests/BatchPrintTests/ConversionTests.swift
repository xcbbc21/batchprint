import XCTest
import PDFKit
import CoreGraphics
@testable import BatchPrint

final class ConversionTests: XCTestCase {
 func testPageSelectionDimensionsAndGrayscale() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source.pdf")
  var sourceBox = CGRect(x: 0, y: 0, width: 300, height: 400)
  let context = CGContext(consumer: CGDataConsumer(url: source as CFURL)!, mediaBox: &sourceBox, nil)!
  for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
   context.beginPDFPage(nil); context.setFillColor(color); context.fill(sourceBox); context.endPDFPage()
  }
  context.closePDF()
  let output = directory.appendingPathComponent("output.pdf")
  var settings = OutputSettings(); settings.pageRange = "2,1"; settings.paper = .letter; settings.landscape = true; settings.grayscale = true
  XCTAssertEqual(try PDFComposer.compose(source: source, destination: output, settings: settings), 2)
  let document = PDFDocument(url: output)!
  XCTAssertEqual(document.page(at: 0)!.bounds(for: .mediaBox).width, 792, accuracy: 0.01)
  XCTAssertEqual(document.page(at: 0)!.bounds(for: .mediaBox).height, 612, accuracy: 0.01)
  // Render a center pixel: all RGB channels must match after true grayscale conversion.
  var intensities: [UInt8] = []
  for index in 0..<2 {
   let raster = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
   let page = document.page(at: index)!.pageRef!
   raster.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x:0,y:0,width:20,height:20), rotate:0, preserveAspectRatio:true)); raster.drawPDFPage(page)
   let pixel = raster.data!.assumingMemoryBound(to: UInt8.self).advanced(by: 10*80+10*4)
   XCTAssertEqual(pixel[0], pixel[1]); XCTAssertEqual(pixel[1], pixel[2]); intensities.append(pixel[0])
  }
  XCTAssertNotEqual(intensities[0], intensities[1], "Reordered red and blue pages should have distinct grayscale intensities")
 }
 @MainActor func testTextDecoding() throws {
  XCTAssertEqual(try Converter.decode(Data("中文".utf8), encoding: "UTF-8"), "中文")
  XCTAssertEqual(try Converter.decode("中文".data(using: .utf16)!, encoding: "自动"), "中文")
  XCTAssertThrowsError(try Converter.decode(Data([0xff, 0xff]), encoding: "UTF-8"))
 }
 func testOutOfBoundsRangeRejectedBeforeWriting() throws {
  XCTAssertThrowsError(try PageSelection.parse("4", count: 3))
  XCTAssertEqual(try PageSelection.parse("3,1-2", count: 3), [2,0,1])
 }
}

extension ConversionTests {
 func testMarkdownEscapesAndStructures() {
  let html = MarkdownRenderer.html("# Heading\n\n- **bold**\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```\n<script>alert(1)</script>\n```")
  XCTAssertTrue(html.contains("<h1>Heading</h1>"))
  XCTAssertTrue(html.contains("<li><strong>bold</strong></li>"))
  XCTAssertTrue(html.contains("<th>A</th>"))
  XCTAssertTrue(html.contains("&lt;script&gt;"))
  XCTAssertFalse(html.contains("<script>"))
 }
 func testWorkbookSelectionAndFitColumns() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let sheetDir = dir.appendingPathComponent("xl/worksheets")
  try FileManager.default.createDirectory(at: sheetDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let workbook = dir.appendingPathComponent("xl/workbook.xml")
  try "<workbook xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><bookViews><workbookView activeTab='0'/></bookViews><sheets><sheet name='收入' sheetId='1'/><sheet name='支出' sheetId='2'/></sheets></workbook>".write(to: workbook, atomically: true, encoding: .utf8)
  let sheet = sheetDir.appendingPathComponent("sheet1.xml")
  try "<worksheet xmlns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'><sheetData/><pageMargins left='1' right='1'/><pageSetup scale='85'/></worksheet>".write(to: sheet, atomically: true, encoding: .utf8)
  try WorkbookPrintSettings.apply(directory: dir, selectedSheets: "支出", fitColumns: true)
  let xml = try XMLDocument(contentsOf: workbook)
  XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='sheet'][@name='收入']/@state").first?.stringValue, "hidden")
  XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='sheet'][@name='支出']/@state").first?.stringValue, "visible")
  let settings = try XMLDocument(contentsOf: sheet)
  XCTAssertEqual(try settings.nodes(forXPath: "//*[local-name()='pageSetup']/@fitToWidth").first?.stringValue, "1")
  XCTAssertTrue(try settings.nodes(forXPath: "//*[local-name()='pageSetup']/@scale").isEmpty)
  XCTAssertThrowsError(try WorkbookPrintSettings.apply(directory: dir, selectedSheets: "不存在", fitColumns: false))
 }
}

extension ConversionTests {
 @MainActor func testPasswordPDFIsActuallyUnlockedOnDisk() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let plain = directory.appendingPathComponent("plain.pdf")
  var rect = CGRect(x: 0, y: 0, width: 300, height: 400)
  let context = CGContext(consumer: CGDataConsumer(url: plain as CFURL)!, mediaBox: &rect, nil)!
  context.beginPDFPage(nil); context.setFillColor(gray: 0.5, alpha: 1); context.fill(rect); context.endPDFPage(); context.closePDF()
  let locked = directory.appendingPathComponent("locked.pdf")
  XCTAssertTrue(PDFDocument(url: plain)!.write(to: locked, withOptions: [.userPasswordOption: "password", .ownerPasswordOption: "owner"]))
  XCTAssertTrue(PDFDocument(url: locked)!.isLocked)
  let converter = Converter()
  do {
   _ = try await converter.convert(source: locked, destination: directory.appendingPathComponent("wrong.pdf"), options: ConversionOptions(), libreOfficePath: "", password: "wrong")
   XCTFail("Wrong password was accepted")
  } catch { XCTAssertTrue(error.localizedDescription.contains("密码")) }
  let result = try await converter.convert(source: locked, destination: directory.appendingPathComponent("unlocked.pdf"), options: ConversionOptions(), libreOfficePath: "", password: "password")
  XCTAssertEqual(result.pageCount, 1)
  XCTAssertFalse(PDFDocument(url: result.url)!.isLocked)
 }
}
