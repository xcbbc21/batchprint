import XCTest
@testable import BatchPrint
final class CoreTests: XCTestCase {
 func testPageRangesRejectInvalidAndPreserveOrder() throws {
  XCTAssertEqual(try PageSelection.parse("3,1-2", count: 5), [2,0,1])
  XCTAssertThrowsError(try PageSelection.parse("0,9", count: 5))
  XCTAssertThrowsError(try PageSelection.parse("3-1", count: 5))
  XCTAssertEqual(try PageSelection.parse("", count: 3), [0,1,2])
 }
 func testPDFSettingsIgnorePhysicalCopies() throws {
  var s = OutputSettings(); s.copies = 7
  XCTAssertEqual(s.target, .pdf)
  XCTAssertEqual(s.effectiveCopies, 1)
 }
 func testUncertainSubmissionNeverBecomesReady() {
  XCTAssertEqual(RecoveryPolicy.recoveredState(.submitting, hasSystemID: false), .needsReview)
  XCTAssertEqual(RecoveryPolicy.recoveredState(.processing, hasSystemID: true), .queued)
 }
 func testNewDefaultsFollowSystemDefaultPrinter() {
  let printers = [
   PrinterInfo(id: "office", displayName: "办公室", isDefault: false),
   PrinterInfo(id: "toshiba", displayName: "TOSHIBA", isDefault: true)
  ]
  XCTAssertEqual(DefaultTargetResolver.resolve(printers: printers, configured: false), .printer("toshiba"))
  XCTAssertEqual(DefaultTargetResolver.resolve(printers: printers, current: .printer("old-default"), configured: false), .printer("toshiba"))
  XCTAssertEqual(DefaultTargetResolver.resolve(printers: printers, current: .printer("chosen"), configured: true), .printer("chosen"))
 }
 func testNewDefaultsUsePDFWhenNoPrinterExists() {
  XCTAssertEqual(DefaultTargetResolver.resolve(printers: [], configured: false), .pdf)
 }
}
