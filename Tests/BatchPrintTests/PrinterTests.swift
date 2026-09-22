import XCTest
@testable import BatchPrint
final class PrinterTests:XCTestCase {
 let toshiba=PrinterBackend.capabilities(options:["PageSize":["A4","A3"],"Duplex":["None","DuplexNoTumble","DuplexTumble"],"ColorType":["Color","Mono"],"Collate":["True","False"]])
 func testToshibaMapping() throws {
  var s=OutputSettings(); s.target = .printer("fixture"); s.grayscale=true; s.duplex = .longEdge; s.copies=2
  let o=try PrinterBackend.jobOptions(settings:s,capabilities:toshiba)
  XCTAssertEqual(o["ColorType"],"Mono"); XCTAssertEqual(o["Duplex"],"DuplexNoTumble"); XCTAssertEqual(o["print-scaling"],"none"); XCTAssertNil(o["page-ranges"]); XCTAssertNil(o["orientation-requested"])
 }
 func testUnsupportedPaperFails() {
  var s=OutputSettings(); s.paper = .letter
  XCTAssertThrowsError(try PrinterBackend.jobOptions(settings:s,capabilities:toshiba))
 }
 func testMissingColorFails() {
  let c=PrinterBackend.capabilities(options:["PageSize":["A4"]])
  XCTAssertThrowsError(try PrinterBackend.jobOptions(settings:OutputSettings(),capabilities:c))
 }
 func testStandardIPPMapping() throws {
  let c=PrinterBackend.capabilities(options:["media":["iso_a4_210x297mm"],"sides":["one-sided","two-sided-short-edge"],"print-color-mode":["color","monochrome"]])
  var s=OutputSettings(); s.duplex = .shortEdge
  let o=try PrinterBackend.jobOptions(settings:s,capabilities:c)
  XCTAssertEqual(o["sides"],"two-sided-short-edge"); XCTAssertEqual(o["media"],"iso_a4_210x297mm")
 }
}
