import AppKit
import PDFKit
import ImageIO
import CoreFoundation

@MainActor final class Converter {
 func convert(source: URL, destination: URL, options: ConversionOptions, libreOfficePath: String, password: String? = nil) async throws -> ConversionResult {
  try Task.checkCancellation()
  let deadline = Date().addingTimeInterval(max(1, options.timeout))
  try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
  let ext = source.pathExtension.lowercased()
  var warnings: [String] = []
  switch ext {
  case "pdf":
   guard let pdf = PDFDocument(url: source) else { throw PrintFailure("PDF 无法读取") }
   if pdf.isLocked { guard let password, pdf.unlock(withPassword: password) else { throw PrintFailure("PDF 已加密，请输入正确密码") } }
   // PDFKit can retain encryption when writing the unlocked source document.
   // A fresh document copies its readable pages without carrying password metadata.
   let output = PDFDocument()
   for index in 0..<pdf.pageCount {
    try Task.checkCancellation()
    guard let page = pdf.page(at: index)?.copy() as? PDFPage else { throw PrintFailure("PDF 页面读取失败") }
    output.insert(page, at: index)
   }
   guard output.write(to: destination) else { throw PrintFailure("PDF 保存失败") }
  case "png", "jpg", "jpeg", "tif", "tiff", "heic", "bmp", "gif", "webp":
   try images(source, destination)
  case "txt", "md", "markdown":
   let text = try Self.decode(Data(contentsOf: source), encoding: options.textEncoding)
   let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
   var html = "<!doctype html><meta charset='utf-8'><style>body{font:12pt -apple-system;line-height:1.55}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}</style><pre>\(escaped)</pre>"
   if ext != "txt" { html = MarkdownRenderer.html(text) }
   try await WebRenderer().render(html: html, baseURL: source.deletingLastPathComponent(), destination: destination, timeout: try remainingTimeout(deadline))
  case "html", "htm":
   let html = try Self.decode(Data(contentsOf: source), encoding: options.textEncoding)
   try await WebRenderer().render(html: html, baseURL: source.deletingLastPathComponent(), destination: destination, timeout: try remainingTimeout(deadline))
  case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "csv":
   guard FileManager.default.isExecutableFile(atPath: libreOfficePath) else { throw PrintFailure("未找到 LibreOffice，请先安装并在设置中指定 soffice 路径") }
   let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BatchPrint-\(UUID().uuidString)", isDirectory: true)
   try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
   defer { try? FileManager.default.removeItem(at: temporary) }
   var input = source
   var args = ["-env:UserInstallation=\(temporary.appendingPathComponent("profile").absoluteString)", "--headless", "--nologo", "--nodefault", "--nofirststartwizard"]
   if ext == "csv" {
    let text = try Self.decode(Data(contentsOf: source), encoding: options.textEncoding)
    input = temporary.appendingPathComponent("input.csv"); try text.write(to: input, atomically: true, encoding: .utf8)
    let delimiter = options.csvDelimiter == "\\t" ? "\t" : options.csvDelimiter
    guard delimiter.unicodeScalars.count == 1, let scalar = delimiter.unicodeScalars.first else { throw PrintFailure("CSV 分隔符必须是单个字符或 \\t") }
    args.append("--infilter=Text - txt - csv (StarCalc):\(scalar.value),34,76,1")
   }
   let isSheet = ["xls", "xlsx", "ods", "csv"].contains(ext)
   if isSheet && (!options.selectedSheets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || options.fitColumns) {
    let intermediate = temporary.appendingPathComponent("xlsx", isDirectory: true)
    try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: true)
    try await runOffice(path: libreOfficePath, arguments: args + ["--convert-to", "xlsx", "--outdir", intermediate.path, input.path], directory: temporary, timeout: try remainingTimeout(deadline))
    let workbook = intermediate.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".xlsx")
    guard FileManager.default.fileExists(atPath: workbook.path) else { throw PrintFailure("无法准备工作表打印设置") }
    let extracted = temporary.appendingPathComponent("unpacked", isDirectory: true)
    try await runOffice(path: "/usr/bin/ditto", arguments: ["-x", "-k", workbook.path, extracted.path], directory: temporary, timeout: try remainingTimeout(deadline))
    try WorkbookPrintSettings.apply(directory: extracted, selectedSheets: options.selectedSheets, fitColumns: options.fitColumns)
    input = temporary.appendingPathComponent("print-settings.xlsx")
    try await runOffice(path: "/usr/bin/ditto", arguments: ["-c", "-k", extracted.path, input.path], directory: temporary, timeout: try remainingTimeout(deadline))
    args.removeAll { $0.hasPrefix("--infilter=") }
    warnings.append("已通过临时 XLSX 应用工作表和按列适配设置；请核对预览中的分页与公式结果")
   }
   args += ["--convert-to", "pdf", "--outdir", temporary.path, input.path]
   try await runOffice(path: libreOfficePath, arguments: args, directory: temporary, timeout: try remainingTimeout(deadline))
   let pdf = temporary.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
   guard FileManager.default.fileExists(atPath: pdf.path) else { throw PrintFailure("LibreOffice 未生成 PDF；请检查源文件是否损坏、受密码保护或包含不受支持内容") }
   if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
   try FileManager.default.copyItem(at: pdf, to: destination)
   warnings.append("Office 转换可能出现字体替换或版式差异，请检查 PDF 预览")
  default: throw PrintFailure("不支持的文件类型：\(ext)")
  }
  try Task.checkCancellation()
  guard let pdf = PDFDocument(url: destination), !pdf.isLocked, pdf.pageCount > 0 else { throw PrintFailure("转换结果不是有效的可读取 PDF") }
  return ConversionResult(url: destination, pageCount: pdf.pageCount, warnings: warnings)
 }
 static func decode(_ data: Data, encoding: String) throws -> String {
  let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
  let encodings: [String.Encoding]
  switch encoding.uppercased() {
  case "UTF-8", "UTF8": encodings = [.utf8]
  case "UTF-16", "UTF16": encodings = [.utf16]
  case "GB18030", "GBK": encodings = [gb]
  default:
   if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { encodings = [.utf16, .utf8, gb] }
   else { encodings = [.utf8, gb] }
  }
  for encoding in encodings { if let value = String(data: data, encoding: encoding) { return value } }
  throw PrintFailure("无法按指定编码读取文本，请选择 UTF-8、UTF-16 或 GB18030")
 }
 private func images(_ source: URL, _ destination: URL) throws {
  guard let images = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(images) > 0 else { throw PrintFailure("图片无法读取") }
  var box = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
  guard let consumer = CGDataConsumer(url: destination as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PrintFailure("图片 PDF 无法创建") }
  defer { context.closePDF() }
  for index in 0..<CGImageSourceGetCount(images) {
   try Task.checkCancellation()
   let properties = CGImageSourceCopyPropertiesAtIndex(images, index, nil) as? [CFString: Any]
   let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 4096
   let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 4096
   let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
   guard let image = CGImageSourceCreateThumbnailAtIndex(images, index, options as CFDictionary) else { throw PrintFailure("图片第 \(index+1) 页无法读取") }
   context.beginPDFPage(nil)
   let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
   let size = CGSize(width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale)
   context.draw(image, in: CGRect(x: (box.width-size.width)/2, y: (box.height-size.height)/2, width: size.width, height: size.height))
   context.endPDFPage()
  }
 }
 private func remainingTimeout(_ deadline: Date) throws -> Double {
  let remaining = deadline.timeIntervalSinceNow
  guard remaining > 0 else { throw PrintFailure("文档转换超时") }
  return remaining
 }
 private func runOffice(path: String, arguments: [String], directory: URL, timeout: Double) async throws {
  let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
  let logURL = directory.appendingPathComponent("conversion.log")
  FileManager.default.createFile(atPath: logURL.path, contents: nil)
  let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
  process.standardOutput = log; process.standardError = log
  try process.run()
  let deadline = Date().addingTimeInterval(max(1, timeout))
  do {
   while process.isRunning {
    try Task.checkCancellation()
    if Date() >= deadline { throw PrintFailure("Office 转换超时，已停止本次独立转换") }
    try await Task.sleep(for: .milliseconds(100))
   }
   guard process.terminationStatus == 0 else {
    let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    throw PrintFailure("Office 转换失败（退出码 \(process.terminationStatus)）：\(details.suffix(1500))")
   }
  } catch {
   if process.isRunning { process.terminate() }
   for _ in 0..<20 { if !process.isRunning { break }; try? await Task.sleep(for: .milliseconds(50)) }
   if process.isRunning { kill(process.processIdentifier, SIGKILL) }
   throw error
  }
 }
}
