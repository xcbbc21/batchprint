import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CSQLite

@MainActor enum SelfTests {
 static func fixturePDF(_ url:URL,pages:Int = 3,label:String = "测试") throws {
  var box = CGRect(x:0,y:0,width:300,height:400)
  guard let sink = CGDataConsumer(url:url as CFURL), let c = CGContext(consumer:sink,mediaBox:&box,nil) else { throw PrintFailure("fixture init") }
  for i in 0..<pages {
   c.beginPDFPage(nil); c.setFillColor(CGColor(red:CGFloat(i+1)/CGFloat(pages+1),green:0.2,blue:0.7,alpha:1)); c.fill(CGRect(x:20,y:20,width:260,height:80))
   let text = NSAttributedString(string:"\(label) PAGE \(i+1)",attributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black])
   c.textPosition = CGPoint(x:20,y:300); CTLineDraw(CTLineCreateWithAttributedString(text),c); c.endPDFPage()
  }; c.closePDF()
 }
 static func fixturePNG(_ url:URL,index:Int) throws {
  let c = CGContext(data:nil,width:64,height:80,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.setFillColor(CGColor(red:CGFloat(index%101)/101,green:0.4,blue:0.8,alpha:0.6)); c.fill(CGRect(x:4,y:6,width:50,height:60))
  let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,c.makeImage()!,nil); guard CGImageDestinationFinalize(dest) else { throw PrintFailure("png fixture") }
 }
 static func run(directory:URL,sampleDirectory:URL?) async throws {
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  var checks:[String] = []; let start = Date()
  func check(_ condition:Bool,_ name:String) throws { guard condition else { throw PrintFailure("FAIL: "+name) }; checks.append(name); print("PASS: "+name); fflush(stdout) }
  let source = directory.appendingPathComponent("原始中文.pdf"); try fixturePDF(source)
  try check(try PageSelection.parse("3,1-2,3",count:3) == [2,0,1],"页码顺序与去重")
  var invalidRejected = false; do { _ = try PageSelection.parse("0-3",count:3) } catch { invalidRejected = true }; try check(invalidRejected,"拒绝页码 0")
  var settings = OutputSettings(); settings.copies = 7
  try check(settings.target == .pdf && settings.effectiveCopies == 1,"无打印机默认 PDF，忽略实体份数")
  settings.pageRange = "3,1"; settings.landscape = true; settings.rotation = 90
  let composed = directory.appendingPathComponent("排版.pdf")
  let pages = try PDFComposer.compose(source:source,destination:composed,settings:settings)
  let doc = PDFDocument(url:composed)!
  try check(pages == 2 && doc.pageCount == 2,"选页且不复制份数")
  try check(abs(doc.page(at:0)!.bounds(for:.mediaBox).width-841.89)<1,"横向纸张尺寸")
  try check(doc.page(at:0)!.string?.contains("PAGE 3") == true && doc.page(at:1)!.string?.contains("PAGE 1") == true,"页面内容顺序保留")
  settings.grayscale = true; let gray = directory.appendingPathComponent("灰度.pdf")
  _ = try PDFComposer.compose(source:source,destination:gray,settings:settings)
  let image = PDFDocument(url:gray)!.page(at:0)!.thumbnail(of:CGSize(width:400,height:300),for:.mediaBox)
  let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
  var neutral = true
  for y in stride(from:0,to:bitmap.pixelsHigh,by:13) { for x in stride(from:0,to:bitmap.pixelsWide,by:13) { if let c = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), abs(c.redComponent-c.greenComponent)>0.015 || abs(c.greenComponent-c.blueComponent)>0.015 { neutral = false } } }
  try check(neutral,"灰度输出像素 RGB 通道一致")
  let exportDir = directory.appendingPathComponent("导出",isDirectory:true); try FileManager.default.createDirectory(at:exportDir,withIntermediateDirectories:true)
  let dest = FileServices.availableOutput(name:"原始中文.pdf",directory:exportDir)
  let originalDigest = try FileServices.sha256(source)
  _ = try FileServices.exportPDF(source:composed,destination:dest,attempt:UUID())
  let second = FileServices.availableOutput(name:"原始中文.pdf",directory:exportDir)
  try check(second != dest && second.lastPathComponent.contains("(1)"),"重名自动编号")
  var collisionRejected = false; do { _ = try FileServices.exportPDF(source:gray,destination:dest,attempt:UUID()) } catch { collisionRejected = true }
  try check(collisionRejected && (try FileServices.sha256(dest)) == (try FileServices.sha256(composed)),"已存在文件原子防覆盖")
  try check(try FileServices.sha256(source) == originalDigest,"源文件未修改")
  let store = try HistoryStore(root:directory.appendingPathComponent("db"))
  var b = Batch(name:"恢复测试"); var d = DocumentItem(name:"原始中文.pdf",sourcePath:source.path,sourceHash:originalDigest)
  var a = OutputAttempt(settings:OutputSettings()); a.outputPath = dest.path; a.checksum = try FileServices.sha256(dest); a.state = .submitting
  d.attempts = [a]; d.state = .submitting; b.documents = [d]
  try store.save(AppSnapshot(batches:[b]))
  let reloaded = try HistoryStore(root:store.root).load()
  try check(reloaded.batches[0].documents[0].attempts[0].id == a.id,"执行标识先持久化且可恢复")
  try check(RecoveryPolicy.recoveredState(.submitting,hasSystemID:false) == .needsReview,"响应丢失禁止自动重提")
  let recovering = AppModel(root:store.root)
  try check(recovering.snapshot.batches[0].documents[0].state == .completed,"导出后崩溃按校验值确认已保存")
  let snapRoot = directory.appendingPathComponent("snapshots"); try FileManager.default.createDirectory(at:snapRoot,withIntermediateDirectories:true)
  let snapshot = try FileServices.snapshot(source:source,root:snapRoot)
  try check(snapshot.sourceHash == FileServices.sha256(URL(fileURLWithPath:snapshot.sourcePath)),"快照哈希对应实际保存内容")
  let legacy = PrinterBackend.capabilities(options:["PageSize":["A4"],"Duplex":["None","DuplexNoTumble","DuplexTumble"],"ColorType":["Color","Mono"],"Collate":["True","False"]])
  var physical = OutputSettings(); physical.target = .printer("test"); physical.duplex = .longEdge; physical.grayscale = true; physical.copies = 2
  let options = try PrinterBackend.jobOptions(settings:physical,capabilities:legacy)
  try check(options["Duplex"] == "DuplexNoTumble" && options["ColorType"] == "Mono" && options["copies"] == "2","TOSHIBA 参数映射")
  physical.paper = .a3; var paperRejected = false; do { _ = try PrinterBackend.jobOptions(settings:physical,capabilities:legacy) } catch { paperRejected = true }; try check(paperRejected,"不支持纸张明确拒绝")
  if let sampleDirectory {
   let samples = try FileManager.default.contentsOfDirectory(at:sampleDirectory,includingPropertiesForKeys:nil).filter {$0.pathExtension.lowercased() == "pdf"}.sorted {$0.lastPathComponent < $1.lastPathComponent}
   let folder = directory.appendingPathComponent("8个PDF回归"); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   for sample in samples {
    let out = FileServices.availableOutput(name:sample.lastPathComponent,directory:folder)
    let n = try PDFComposer.compose(source:sample,destination:out,settings:OutputSettings())
    try check(n == PDFDocument(url:sample)?.pageCount && PDFDocument(url:out)?.pageCount == n,"源样本 \(sample.lastPathComponent)：\(n) 页")
   }
   try check(samples.count == 8,"8 个现有 PDF 全部覆盖")
  }
  let stressRoot = directory.appendingPathComponent("stress")
  let model = AppModel(root:stressRoot)
  let fixtures = directory.appendingPathComponent("200fixtures"); try FileManager.default.createDirectory(at:fixtures,withIntermediateDirectories:true)
  var stressBatch = Batch(name:"200 文件混合验证")
  for i in 0..<200 {
   let file = fixtures.appendingPathComponent(i%2 == 0 ? "样本\(i).pdf" : "样本\(i).png")
   if i%2 == 0 { try fixturePDF(file,pages:1,label:"测试\(i)") } else { try fixturePNG(file,index:i/2) }
   stressBatch.documents.append(try FileServices.snapshot(source:file,root:model.store!.files))
  }
  model.snapshot.batches = [stressBatch]; model.selectedBatch = stressBatch.id; _ = model.persist()
  model.startPreparing()
  let deadline = Date().addingTimeInterval(300); var heartbeats = 0
  while model.preparing && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000); heartbeats += 1 }
  try check(model.currentBatch!.documents.filter {$0.state == .ready}.count == 200,"200 个 PDF/PNG 混合文件转换成功")
  try check(heartbeats > 0,"批量转换期间主事件循环可响应")
  let stressOut = directory.appendingPathComponent("200exports"); try FileManager.default.createDirectory(at:stressOut,withIntermediateDirectories:true)
  model.run(batchID:stressBatch.id,ids:stressBatch.documents.map(\.id),exportDirectory:stressOut)
  let outputDeadline = Date().addingTimeInterval(300)
  while model.running && Date()<outputDeadline { try await Task.sleep(nanoseconds:50_000_000) }
  try check(model.currentBatch!.documents.filter {$0.state == .completed}.count == 200,"200 文件顺序导出及历史成功")
  try check(try FileManager.default.contentsOfDirectory(at:stressOut,includingPropertiesForKeys:nil).filter {$0.pathExtension == "pdf"}.count == 200,"批量输出数量精确")
  let faultPrinter = LostResponsePrinter()
  let faultRoot = directory.appendingPathComponent("fault-recovery")
  let faultModel = AppModel(root:faultRoot,printerBackend:faultPrinter)
  var faultBatch = Batch(name:"已接受但响应丢失")
  faultBatch.settings.target = .printer("fault-fixture")
  var faultDoc = DocumentItem(name:"故障注入.pdf",sourcePath:source.path,sourceHash:originalDigest)
  faultDoc.pdfPath = source.path; faultDoc.state = .ready; faultBatch.documents = [faultDoc]
  faultModel.snapshot.batches = [faultBatch]; faultModel.selectedBatch = faultBatch.id; _ = faultModel.persist()
  faultModel.run(batchID:faultBatch.id,ids:[faultDoc.id],exportDirectory:nil)
  while faultModel.running { try await Task.sleep(nanoseconds:20_000_000) }
  try check(faultPrinter.submissionCount == 1 && faultModel.currentBatch!.documents[0].state == .needsReview,"真实队列故障注入：已接收但响应丢失，暂停并需核实")
  let restoredFaultModel = AppModel(root:faultRoot,printerBackend:faultPrinter)
  for _ in 0..<100 { if restoredFaultModel.currentBatch!.documents[0].state == .completed { break }; try await Task.sleep(nanoseconds:20_000_000) }
  try check(faultPrinter.submissionCount == 1 && restoredFaultModel.currentBatch!.documents[0].state == .completed,"重启按执行标识找回任务，无重复提交")
  let corruptRoot = directory.appendingPathComponent("corrupt-history")
  let corruptStore = try HistoryStore(root:corruptRoot); try corruptStore.save(AppSnapshot())
  var db:OpaquePointer?; sqlite3_open(corruptRoot.appendingPathComponent("history.sqlite").path,&db)
  sqlite3_exec(db,"UPDATE app_state SET payload='corrupt-fixture' WHERE id=1",nil,nil,nil); sqlite3_close(db)
  let corruptModel = AppModel(root:corruptRoot,printerBackend:LostResponsePrinter())
  corruptModel.newBatch()
  try check(corruptModel.store == nil && !corruptModel.persist(),"损坏历史禁止后续覆盖写入")
  let cancelledDestination = exportDir.appendingPathComponent("应取消.pdf")
  let cancelledAttempt = UUID()
  let cancelledExport = Task { @MainActor in try FileServices.exportPDF(source:composed,destination:cancelledDestination,attempt:cancelledAttempt) }
  cancelledExport.cancel()
  var cancellationObserved = false
  do { _ = try await cancelledExport.value } catch is CancellationError { cancellationObserved = true }
  try check(cancellationObserved && !FileManager.default.fileExists(atPath:cancelledDestination.path) && !FileManager.default.fileExists(atPath:exportDir.appendingPathComponent(".batchprint-\(cancelledAttempt.uuidString).tmp").path),"取消导出不留下目标或临时文件")
  let retentionModel = AppModel(root:directory.appendingPathComponent("retention"),printerBackend:LostResponsePrinter())
  var expired = try FileServices.snapshot(source:source,root:retentionModel.store!.files)
  expired.created = Date().addingTimeInterval(-40*86400); expired.state = .completed; expired.pdfPath = expired.sourcePath
  var retainedOutput = OutputAttempt(settings:OutputSettings()); retainedOutput.outputPath = dest.path; retainedOutput.state = .completed
  expired.attempts = [retainedOutput]
  var retentionBatch = Batch(name:"清理测试"); retentionBatch.documents = [expired]
  retentionModel.snapshot.batches = [retentionBatch]; retentionModel.selectedBatch = retentionBatch.id
  while retentionModel.preparing { await Task.yield() }
  retentionModel.cleanup()
  try check(!FileManager.default.fileExists(atPath:expired.sourcePath) && FileManager.default.fileExists(atPath:dest.path),"清理仅移除过期内部文件，保留用户导出")
  let preview = PDFPreviewContainer(frame:NSRect(x:0,y:0,width:600,height:400))
  let window = NSWindow(contentRect:preview.frame,styleMask:.borderless,backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false; window.contentView = preview
  preview.pdfView.document = PDFDocument(url:composed)
  preview.layoutSubtreeIfNeeded(); preview.fitPage()
  let scale = preview.pdfView.scaleFactor
  try check(scale > 0.3 && scale < 1.0,"预览按实际窗口尺寸整页适配")
  window.contentView = nil; window.close()
  let deletionModel = AppModel(root:directory.appendingPathComponent("deletion"),printerBackend:LostResponsePrinter())
  while deletionModel.preparing { await Task.yield() }
  var deleteBatchFixture = Batch(name:"删除与撤销")
  var deletedDoc = DocumentItem(name:"删除测试.pdf",sourcePath:source.path,sourceHash:originalDigest)
  deletedDoc.pdfPath = source.path; deletedDoc.state = .cancelled
  var keepDoc = deletedDoc; keepDoc.id = UUID(); keepDoc.name = "保留测试.pdf"; keepDoc.state = .ready
  deleteBatchFixture.documents = [deletedDoc,keepDoc]
  deletionModel.snapshot.batches = [deleteBatchFixture]; deletionModel.selectedBatch = deleteBatchFixture.id; deletionModel.selection = [deletedDoc.id]; _ = deletionModel.persist()
  try check(deletionModel.deleteDocuments(batchID:deleteBatchFixture.id,ids:[deletedDoc.id]) && deletionModel.currentBatch!.documents.map(\.id) == [keepDoc.id],"可删除已取消任务并保留其他文件")
  try check(FileManager.default.fileExists(atPath:source.path) && FileManager.default.fileExists(atPath:dest.path),"删除记录不会删除原文件或已导出的 PDF")
  try check(try deletionModel.store!.load().batches[0].documents.count == 1,"删除结果持久化")
  deletionModel.undoDeletion()
  try check(deletionModel.currentBatch!.documents.map(\.id) == [deletedDoc.id,keepDoc.id],"撤销删除恢复原顺序")
  deletionModel.update(deleteBatchFixture.id,keepDoc.id) { $0.state = .queued }
  try check(!deletionModel.deleteBatch(deleteBatchFixture.id) && deletionModel.snapshot.batches.count == 1,"禁止删除含系统排队任务的批次")
  deletionModel.update(deleteBatchFixture.id,keepDoc.id) { $0.state = .needsReview }
  try check(!deletionModel.deleteDocuments(batchID:deleteBatchFixture.id,ids:[keepDoc.id]),"需核实任务不会被删除而丢失追踪")
  deletionModel.update(deleteBatchFixture.id,keepDoc.id) { $0.state = .completed }
  try check(deletionModel.deleteBatch(deleteBatchFixture.id) && deletionModel.snapshot.batches.isEmpty && deletionModel.selectedBatch == nil,"可删除最后一个批次")
  deletionModel.undoDeletion()
  try check(deletionModel.snapshot.batches.count == 1 && deletionModel.currentBatch!.documents.count == 2,"撤销删除批次恢复全部文件")
  let empty = Batch(name:"空批次"); deletionModel.snapshot.batches.append(empty)
  try check(deletionModel.deleteBatch(empty.id) && deletionModel.snapshot.batches.count == 1,"空批次可以删除")
  let report:[String:Any] = ["passed":checks.count,"checks":checks,"seconds":Date().timeIntervalSince(start),"physicalPrinting": "未在此自动测试中提交", "architecture": "arm64", "xctest": "本机仅命令行 SDK，使用实际功能自测入口"]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
  print("SELFTEST PASS \(checks.count) checks")
 }
}

// Fault fixture is reachable only from --self-test and never used by the application model defaults.
final class LostResponsePrinter: PrinterService, @unchecked Sendable {
 private let lock = NSLock(); private var submitted = 0
 var submissionCount:Int { lock.lock(); defer { lock.unlock() }; return submitted }
 func printers() throws -> [PrinterInfo] { [PrinterInfo(id:"fault-fixture",displayName:"测试打印机")] }
 func capabilities(printer:String) throws -> PrinterCapabilities { PrinterCapabilities(papers:["A4"],supportsDuplex:true,supportsColor:true) }
 func validate(settings:OutputSettings) throws {}
 func submit(pdf:URL,settings:OutputSettings,attemptID:UUID) throws -> Int { lock.lock(); submitted += 1; lock.unlock(); throw PrintFailure("模拟系统已接收，但返回响应丢失") }
 func status(printer:String,jobID:Int) -> PrinterJobStatus { .completed }
 func cancel(printer:String,jobID:Int) throws {}
 func findJob(printer:String,attemptID:UUID) throws -> Int? { submissionCount > 0 ? 77 : nil }
}
