import Foundation
import CCups

protocol PrinterService: Sendable {
 func printers() throws -> [PrinterInfo]
 func capabilities(printer:String) throws -> PrinterCapabilities
 func validate(settings:OutputSettings) throws
 func submit(pdf:URL,settings:OutputSettings,attemptID:UUID) throws -> Int
 func status(printer:String,jobID:Int) -> PrinterJobStatus
 func cancel(printer:String,jobID:Int) throws
 func findJob(printer:String,attemptID:UUID) throws -> Int?
}

struct PrinterBackend: PrinterService {
 func printers() throws -> [PrinterInfo] {
  var dests: UnsafeMutablePointer<cups_dest_t>?
  let count = cupsGetDests(&dests)
  defer { cupsFreeDests(count, dests) }
  guard count >= 0 else { throw PrintFailure("无法读取打印机列表") }
  return (0..<Int(count)).compactMap { i in
   guard let d = dests?[i], let name = d.name, d.instance == nil else { return nil }
   let label = cupsGetOption("printer-info", d.num_options, d.options).map { String(cString:$0) } ?? String(cString:name)
   return PrinterInfo(id:String(cString:name), displayName:label, isDefault:d.is_default != 0)
  }
 }
 func capabilities(printer: String) throws -> PrinterCapabilities {
  guard let dest = cupsGetNamedDest(nil, printer, nil) else { throw PrintFailure("打印机不存在：\(printer)") }
  defer { cupsFreeDests(1, dest) }
  var options: [String:[String]] = [:]
  if !printer.contains("/"), !printer.contains("..") {
   let url = URL(fileURLWithPath:"/etc/cups/ppd").appendingPathComponent(printer+".ppd")
   if let data = try? String(contentsOf:url, encoding:.utf8) {
    // PPD choice records: *Duplex DuplexNoTumble/Long Edge: ...
    let regex = try NSRegularExpression(pattern:"(?m)^\\*([A-Za-z][A-Za-z0-9_-]*) ([^/ :\\r\\n]+)(?:/[^:\\r\\n]*)?:")
    for match in regex.matches(in:data, range:NSRange(data.startIndex...,in:data)) {
     guard let a = Range(match.range(at:1),in:data), let b = Range(match.range(at:2),in:data) else { continue }
     let key=String(data[a]), value=String(data[b])
     if !(options[key] ?? []).contains(value) { options[key, default:[]].append(value) }
    }
   }
  }
  if options["PageSize"] == nil, let info = cupsCopyDestInfo(nil,dest) {
   defer { cupsFreeDestInfo(info) }
   for key in ["media","sides","print-color-mode","multiple-document-handling"] {
    if let attr = cupsFindDestSupported(nil,dest,info,key) {
     options[key] = (0..<ippGetCount(attr)).compactMap { ippGetString(attr,$0,nil).map { String(cString:$0) } }
    }
   }
  }
  return Self.capabilities(options:options)
 }
 static func capabilities(options:[String:[String]]) -> PrinterCapabilities {
  PrinterCapabilities(papers:options["PageSize"] ?? options["media"] ?? [], supportsDuplex:(options["Duplex"] ?? []).contains(where: { $0 == "DuplexNoTumble" || $0 == "DuplexTumble" }) || (options["sides"] ?? []).contains(where: { $0.hasPrefix("two-sided-") }), supportsColor:(options["ColorType"] ?? []).contains("Color") || (options["ColorModel"] ?? []).contains("RGB") || (options["print-color-mode"] ?? []).contains("color"), options:options)
 }
 static func jobOptions(settings:OutputSettings, capabilities c:PrinterCapabilities) throws -> [String:String] {
  guard (1...999).contains(settings.copies) else { throw PrintFailure("打印份数应为 1–999") }
  var result = ["copies":String(settings.copies), "print-scaling":"none", "fit-to-page":"false", "number-up":"1"]
  func choose(_ key:String,_ value:String) throws {
   guard c.options[key]?.contains(value) == true else { throw PrintFailure("打印机不支持 \(key)=\(value)，请修改设置") }
   result[key]=value
  }
  if c.options["PageSize"] != nil { try choose("PageSize",settings.paper.rawValue) }
  else {
   let media:[Paper:String] = [.a4:"iso_a4_210x297mm",.a3:"iso_a3_297x420mm",.a5:"iso_a5_148x210mm",.letter:"na_letter_8.5x11in"]
   try choose("media",media[settings.paper]!)
  }
  if c.options["Duplex"] != nil { try choose("Duplex",settings.duplex == .single ? "None" : settings.duplex == .longEdge ? "DuplexNoTumble" : "DuplexTumble") }
  else if c.options["sides"] != nil { try choose("sides",settings.duplex == .single ? "one-sided" : settings.duplex == .longEdge ? "two-sided-long-edge" : "two-sided-short-edge") }
  else if settings.duplex != .single { throw PrintFailure("打印机未公布双面打印能力") }
  else { result["sides"]="one-sided" }
  if c.options["ColorType"] != nil { try choose("ColorType",settings.grayscale ? "Mono":"Color") }
  else if c.options["ColorModel"] != nil { try choose("ColorModel",settings.grayscale ? "Gray":"RGB") }
  else if c.options["print-color-mode"] != nil { try choose("print-color-mode",settings.grayscale ? "monochrome":"color") }
  else if !settings.grayscale { throw PrintFailure("无法确认打印机彩色能力，请选择灰度或核实驱动") }
  if c.options["Collate"] != nil { try choose("Collate",settings.collate ? "True":"False") }
  else if settings.copies > 1 { try choose("multiple-document-handling",settings.collate ? "separate-documents-collated-copies":"separate-documents-uncollated-copies") }
  return result
 }
 func validate(settings:OutputSettings) throws {
  guard case .printer(let name)=settings.target else { return }
  _ = try Self.jobOptions(settings:settings,capabilities:capabilities(printer:name))
 }
 func submit(pdf:URL,settings:OutputSettings,attemptID:UUID) throws -> Int {
  guard case .printer(let name)=settings.target else { throw PrintFailure("未选择实体打印机") }
  let values = try Self.jobOptions(settings:settings,capabilities:capabilities(printer:name))
  guard FileManager.default.isReadableFile(atPath:pdf.path) else { throw PrintFailure("输出 PDF 不可读取") }
  var options:UnsafeMutablePointer<cups_option_t>?; var count:Int32=0
  defer { cupsFreeOptions(count,options) }
  for (key,value) in values { count=cupsAddOption(key,value,count,&options) }
  let id=cupsPrintFile(name,pdf.path,Self.title(attemptID),count,options)
  guard id > 0 else { throw PrintFailure("CUPS 提交失败：\(String(cString:cupsLastErrorString()))") }
  return Int(id)
 }
 static func title(_ id:UUID)->String { "BatchPrint-"+id.uuidString }
 func status(printer:String,jobID:Int)->PrinterJobStatus {
  var jobs:UnsafeMutablePointer<cups_job_t>?
  let count=cupsGetJobs(&jobs,printer,1,CUPS_WHICHJOBS_ALL)
  defer { if count > 0 { cupsFreeJobs(count,jobs) } }
  guard count >= 0, let jobs=jobs else { return .unknown }
  for i in 0..<Int(count) where jobs[i].id == jobID {
   switch jobs[i].state {
   case IPP_JSTATE_PENDING,IPP_JSTATE_HELD: return .pending
   case IPP_JSTATE_PROCESSING: return .processing
   case IPP_JSTATE_COMPLETED:return .completed
   case IPP_JSTATE_CANCELED:return .cancelled
   case IPP_JSTATE_ABORTED:return .failed("CUPS 已中止任务")
   case IPP_JSTATE_STOPPED:return .pending // A stopped job can resume; keep it locked against duplicate retries.
   default:return .unknown
   }
  }
  return .unknown
 }
 func cancel(printer:String,jobID:Int) throws {
  guard jobID > 0, cupsCancelJob(printer,Int32(jobID)) == 1 else { throw PrintFailure("取消任务失败：\(String(cString:cupsLastErrorString()))") }
 }
 func findJob(printer:String,attemptID:UUID) throws -> Int? {
  var jobs:UnsafeMutablePointer<cups_job_t>?
  let count=cupsGetJobs(&jobs,printer,1,CUPS_WHICHJOBS_ALL)
  defer { if count > 0 { cupsFreeJobs(count,jobs) } }
  guard count >= 0 else { throw PrintFailure("无法核实 CUPS 历史任务") }
  guard let jobs=jobs else { return nil }
  let matches=(0..<Int(count)).filter { jobs[$0].title.map { String(cString:$0) } == Self.title(attemptID) }
  guard matches.count <= 1 else { throw PrintFailure("发现多个相同提交标记，需要人工核实") }
  return matches.first.map { Int(jobs[$0].id) }
 }
}
