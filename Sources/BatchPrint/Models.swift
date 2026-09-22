import Foundation

enum OutputTarget: Codable, Hashable {
 case pdf
 case printer(String)
 var isPDF: Bool { if case .pdf = self { return true }; return false }
 var label: String { switch self { case .pdf: return "打印到 PDF"; case .printer(let name): return name } }
}
enum Paper: String, Codable, CaseIterable { case a4 = "A4", a3 = "A3", letter = "Letter", a5 = "A5"
 var points: CGSize { switch self { case .a4: return CGSize(width: 595.276, height: 841.89); case .a3: return CGSize(width: 841.89, height: 1190.551); case .letter: return CGSize(width: 612, height: 792); case .a5: return CGSize(width: 419.528, height: 595.276) } }
}
enum DuplexMode: String, Codable, CaseIterable { case single = "单面", longEdge = "长边双面", shortEdge = "短边双面" }
struct OutputSettings: Codable, Equatable {
 var target: OutputTarget = .pdf
 var paper: Paper = .a4
 var landscape = false
 var pageRange = ""
 var fitToPage = true
 var rotation = 0
 var grayscale = false
 var duplex: DuplexMode = .single
 var copies = 1
 var collate = true
 var effectiveCopies: Int { target.isPDF ? 1 : copies }
 var pageSize: CGSize { let s = paper.points; return landscape ? CGSize(width:s.height, height:s.width) : s }
}
struct ConversionOptions: Codable, Equatable {
 var textEncoding = "自动"
 var csvDelimiter = ","
 var selectedSheets = ""
 var fitColumns = false
 var timeout: Double = 180
}
enum JobState: String, Codable, CaseIterable {
 case preparing = "准备中", ready = "待执行", submitting = "提交中", queued = "系统排队", processing = "执行中", completed = "已完成", failed = "失败", cancelled = "已取消", needsReview = "需核实"
 var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
 var locked: Bool { [.submitting, .queued, .processing, .completed, .needsReview].contains(self) }
}
struct StateEvent: Codable, Identifiable {
 var id = UUID(); var date = Date(); var message: String
}
struct OutputAttempt: Codable, Identifiable {
 var id = UUID(); var date = Date(); var settings: OutputSettings
 var state: JobState = .submitting
 var systemJobID: Int?; var outputPath: String?; var checksum: String?
 var events: [StateEvent] = []
}
struct DocumentItem: Codable, Identifiable {
 var id = UUID(); var name: String; var sourcePath: String; var sourceHash: String
 var originalURL: String?; var pdfPath: String?; var composedPath: String?
 var pageCount = 0; var state: JobState = .preparing
 var settingsOverride: OutputSettings?; var conversion = ConversionOptions()
 var warnings: [String] = []; var error: String?; var attempts: [OutputAttempt] = []
 var created = Date()
}
struct Batch: Codable, Identifiable {
 var id = UUID(); var name: String; var created = Date(); var settings = OutputSettings()
 var documents: [DocumentItem] = []
}
struct PrintTemplate: Codable, Identifiable { var id = UUID(); var name: String; var settings: OutputSettings }
struct AppPreferences: Codable {
 var defaultSettings = OutputSettings(); var defaultTargetConfigured = false
 var libreOfficePath = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
 var conversionTimeout: Double = 180; var lastExportDirectory = ""
 var cacheDays = 30; var historyDays = 180
 private enum CodingKeys: String, CodingKey { case defaultSettings, defaultTargetConfigured, libreOfficePath, conversionTimeout, lastExportDirectory, cacheDays, historyDays }
 init() {}
 init(from decoder: Decoder) throws {
  let c = try decoder.container(keyedBy: CodingKeys.self)
  defaultSettings = try c.decodeIfPresent(OutputSettings.self,forKey:.defaultSettings) ?? OutputSettings()
  // Older snapshots did not record whether the user chose the default target.
  // A legacy PDF value is therefore migrated to the current system printer.
  defaultTargetConfigured = try c.decodeIfPresent(Bool.self,forKey:.defaultTargetConfigured) ?? !defaultSettings.target.isPDF
  libreOfficePath = try c.decodeIfPresent(String.self,forKey:.libreOfficePath) ?? "/Applications/LibreOffice.app/Contents/MacOS/soffice"
  conversionTimeout = try c.decodeIfPresent(Double.self,forKey:.conversionTimeout) ?? 180
  lastExportDirectory = try c.decodeIfPresent(String.self,forKey:.lastExportDirectory) ?? ""
  cacheDays = try c.decodeIfPresent(Int.self,forKey:.cacheDays) ?? 30
  historyDays = try c.decodeIfPresent(Int.self,forKey:.historyDays) ?? 180
 }
}
struct AppSnapshot: Codable { var batches: [Batch] = []; var templates: [PrintTemplate] = []; var preferences = AppPreferences() }
struct PrintFailure: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ message: String) { self.message = message } }
struct ConversionResult { var url: URL; var pageCount: Int; var warnings: [String] = [] }
struct PrinterInfo: Identifiable, Hashable { var id: String; var displayName: String; var isDefault = false }
enum DefaultTargetResolver {
 static func resolve(printers: [PrinterInfo], current: OutputTarget = .pdf, configured: Bool) -> OutputTarget {
  guard !configured, let printer = printers.first(where: \.isDefault) else { return current }
  return .printer(printer.id)
}
}
struct PrinterCapabilities {
 var papers: [String] = []; var supportsDuplex = false; var supportsColor = false
 var options: [String: [String]] = [:]
}
enum PrinterJobStatus { case pending, processing, completed, cancelled, failed(String), unknown }
enum PageSelection {
 static func parse(_ value: String, count: Int) throws -> [Int] {
  guard count > 0 else { throw PrintFailure("PDF 没有可输出的页面") }
  if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(0..<count) }
  var result: [Int] = []; var seen = Set<Int>()
  for token in value.replacingOccurrences(of: "，", with: ",").split(separator: ",", omittingEmptySubsequences: false) {
   let parts = token.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
   guard (1...2).contains(parts.count), let first = Int(parts[0]), first > 0, first <= count else { throw PrintFailure("页码范围无效，请使用 1-3,5（共 \(count) 页）") }
   let last: Int
   if parts.count == 2 { guard let end = Int(parts[1]), end >= first, end <= count else { throw PrintFailure("页码范围超出文档或顺序错误") }; last = end } else { last = first }
   for n in first...last where seen.insert(n).inserted { result.append(n-1) }
  }
  return result
 }
}
enum RecoveryPolicy {
 static func recoveredState(_ state: JobState, hasSystemID: Bool) -> JobState {
  switch state { case .submitting, .processing, .queued: return hasSystemID ? .queued : .needsReview; default: return state }
 }
}
