import SwiftUI
import AppKit
import PDFKit

@MainActor final class AppModel: ObservableObject {
 @Published var snapshot = AppSnapshot()
 @Published var selectedBatch: UUID?
 @Published var selection = Set<UUID>()
 @Published var section = "批次"
 @Published var search = ""
 @Published var printers: [PrinterInfo] = []
 @Published var capabilities: [String: PrinterCapabilities] = [:]
 @Published var message: String?
 @Published var running = false
 @Published var paused = false
 @Published var preparing = false
 @Published var previewURL: URL?
 @Published var previewBusy = false
 @Published var settingsVisible = false
 @Published var webVisible = false
 @Published var recursiveImport = true
 @Published var previewError: String?
 @Published var deletionNotice: String?
 private enum DeletedRecords { case documents(UUID, [(Int, DocumentItem)]); case batch(Int, Batch) }
 private var lastDeletion: DeletedRecords?
 private var importCounts: [UUID:Int] = [:]
 private(set) var store: HistoryStore?
 private let backend: any PrinterService
 private let converter = Converter()
 private var queueTask: Task<Void, Never>?
 private var prepareTask: Task<Void, Never>?
 private var previewTask: Task<Void, Never>?
 private var previewWork: Task<Int, Error>?
 private var activeExport: Task<String, Error>?
 private var activeExportID: UUID?
 private var activeConversion: Task<ConversionResult, Error>?
 private var activeConversionID: UUID?
 private var passwords: [UUID: String] = [:]
 private var cancelled = Set<UUID>()
 private var recoveryTasks: [Task<Void, Never>] = []
 init(root: URL? = nil, printerBackend: any PrinterService = PrinterBackend()) {
  backend = printerBackend
  do {
   let override = CommandLine.arguments.firstIndex(of:"--data-root").flatMap { CommandLine.arguments.count > $0+1 ? URL(fileURLWithPath:CommandLine.arguments[$0+1]) : nil }
   let base = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BatchPrint", isDirectory: true)
   let store = try HistoryStore(root: base); let loaded = try store.load(); self.store = store; snapshot = loaded
   selectedBatch = snapshot.batches.first?.id
   recover()
  } catch { message = "无法初始化数据目录：\(error.localizedDescription)" }
  refreshPrinters()
 }
 var currentBatch: Batch? { snapshot.batches.first { $0.id == selectedBatch } }
 var selectedItem: DocumentItem? { currentBatch?.documents.first { selection.contains($0.id) } }
 var visibleDocuments: [DocumentItem] {
  let documents = currentBatch?.documents ?? []
  return documents.filter { item in
   let match = search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
   switch section { case "失败": return match && [.failed,.needsReview].contains(item.state); case "进行中": return match && !item.state.terminal; case "历史": return match && (item.state.terminal || !item.attempts.isEmpty); default: return match }
  }
 }
 func settings(for item: DocumentItem, batch: Batch? = nil) -> OutputSettings { item.settingsOverride ?? batch?.settings ?? currentBatch?.settings ?? snapshot.preferences.defaultSettings }
 var outputSummary: String {
  let docs = currentBatch?.documents ?? []; var pages = 0; var sheets = 0
  for doc in docs where doc.pageCount > 0 { let s = settings(for:doc); let n = (try? PageSelection.parse(s.pageRange,count:doc.pageCount).count) ?? 0; pages += n*s.effectiveCopies; if !s.target.isPDF { sheets += (s.duplex == .single ? n : (n+1)/2)*s.copies } }
  return "\(docs.count) 个文件 · \(pages) 输出页" + (sheets > 0 ? " · 约 \(sheets) 张纸" : "")
 }
 var actionTitle: String {
  let docs = currentBatch?.documents.filter { $0.state == .ready } ?? []
  let targets = docs.map { settings(for:$0).target.isPDF }
  if targets.isEmpty { return currentBatch?.settings.target.isPDF == false ? "开始打印" : "保存 PDF" }
  if targets.allSatisfy({$0}) { return "保存 PDF" }
  if targets.allSatisfy({!$0}) { return "开始打印" }; return "开始输出"
 }
 @discardableResult func persist() -> Bool {
  do { guard let store else { throw PrintFailure("数据目录不可用") }; try store.save(snapshot); return true }
  catch { paused = true; message = error.localizedDescription; return false }
 }
 func newBatch(template: PrintTemplate? = nil) {
  let name = "批次 " + Date().formatted(date: .numeric, time: .shortened)
  let batch = Batch(name: name, settings: template?.settings ?? snapshot.preferences.defaultSettings)
  snapshot.batches.insert(batch, at: 0); selectedBatch = batch.id; selection = []; section = "批次"; persist()
 }
 func update(_ bid: UUID, _ iid: UUID, _ body: (inout DocumentItem) -> Void) {
  guard let b = snapshot.batches.firstIndex(where: {$0.id == bid}), let i = snapshot.batches[b].documents.firstIndex(where: {$0.id == iid}) else { return }
  body(&snapshot.batches[b].documents[i])
 }
 func item(_ bid: UUID, _ iid: UUID) -> DocumentItem? { snapshot.batches.first(where: {$0.id == bid})?.documents.first(where: {$0.id == iid}) }
 func refreshPrinters() {
  Task {
   do {
    let list = try await Task.detached { [backend] in try backend.printers() }.value
    printers = list
    for p in list { let cap = try? await Task.detached { [backend] in try backend.capabilities(printer: p.id) }.value; capabilities[p.id] = cap }
   } catch { message = "读取打印机失败：\(error.localizedDescription)；仍可打印到 PDF" }
  }
 }
 func chooseFiles(folder: Bool = false) {
  guard store != nil else { return }
  let panel = NSOpenPanel(); panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = true
  panel.message = folder ? "选择文件夹；是否包含子文件夹由工具栏选项决定" : "选择 PDF、办公文档、图片、网页或文本"
  if panel.runModal() == .OK { importURLs(panel.urls) }
 }
 func importURLs(_ urls: [URL]) {
  guard let store else { return }
  if selectedBatch == nil { newBatch() }
  guard let bid = selectedBatch else { return }
  importCounts[bid, default:0] += 1
  let recursive = recursiveImport
  Task {
   defer { importCounts[bid, default:1] -= 1; if importCounts[bid] == 0 { importCounts.removeValue(forKey:bid) }; objectWillChange.send() }
   do {
    let sources = try await Task.detached { try FileServices.importFiles(urls, recursive: recursive) }.value
    var keepAllDuplicates = false
    for source in sources {
     let newItem = try await Task.detached { try FileServices.snapshot(source: source, root: store.files) }.value
     let duplicate = snapshot.batches.first(where: {$0.id == bid})?.documents.contains(where: {$0.sourceHash == newItem.sourceHash}) == true
     if duplicate && !keepAllDuplicates {
      let alert = NSAlert(); alert.messageText = "发现重复内容：\(newItem.name)"; alert.informativeText = "可以保留用于重复输出，或跳过此文件。"; alert.addButton(withTitle:"保留"); alert.addButton(withTitle:"跳过"); alert.addButton(withTitle:"本次全部保留")
      let response = alert.runModal()
      if response == .alertSecondButtonReturn { try? FileManager.default.removeItem(at: URL(fileURLWithPath:newItem.sourcePath).deletingLastPathComponent()); continue }
      if response == .alertThirdButtonReturn { keepAllDuplicates = true }
     }
     if let b = snapshot.batches.firstIndex(where: {$0.id == bid}) {
      var item = newItem; item.conversion.timeout = snapshot.preferences.conversionTimeout
      snapshot.batches[b].documents.append(item)
      if selectedBatch == bid && selection.isEmpty { selection = [item.id] }
     }
     guard persist() else { return }
     startPreparing()
    }
   } catch { message = "导入失败：\(error.localizedDescription)" }
  }
 }
 func startPreparing() {
  guard !preparing else { return }
  preparing = true
  prepareTask = Task {
   defer { preparing = false; prepareTask = nil }
   while !Task.isCancelled {
    guard let batch = snapshot.batches.first(where: {$0.documents.contains(where: {$0.state == .preparing})}), let doc = batch.documents.first(where: {$0.state == .preparing}) else { break }
    do {
     let dir = URL(fileURLWithPath:doc.sourcePath).deletingLastPathComponent()
     let dest = dir.appendingPathComponent("converted-\(UUID().uuidString).pdf")
     activeConversionID = doc.id
     let conversionTask = Task { try await converter.convert(source: URL(fileURLWithPath:doc.sourcePath), destination: dest, options: doc.conversion, libreOfficePath: snapshot.preferences.libreOfficePath, password: passwords[doc.id]) }
     activeConversion = conversionTask
     defer { activeConversion = nil; activeConversionID = nil }
     let result = try await conversionTask.value
     if cancelled.contains(doc.id) { try? FileManager.default.removeItem(at: result.url); continue }
     update(batch.id,doc.id) { $0.pdfPath = result.url.path; $0.pageCount = result.pageCount; $0.warnings = result.warnings; $0.state = .ready; $0.error = nil }
     persist()
     await Task.yield()
     if selection.contains(doc.id) { refreshPreview() }
    } catch {
     if cancelled.contains(doc.id) { continue }
     update(batch.id,doc.id) { $0.state = .failed; $0.error = error.localizedDescription }; persist()
    }
   }
  }
 }
 func setPassword(_ password: String) { guard let doc = selectedItem, let bid = selectedBatch, !doc.state.locked, doc.state != .preparing else { return }; passwords[doc.id] = password; update(bid,doc.id) {$0.state = .preparing; $0.error = nil}; cancelled.remove(doc.id); persist(); startPreparing() }
 func changeSettings(_ settings: OutputSettings, individual: Bool) {
  guard let b = snapshot.batches.firstIndex(where: {$0.id == selectedBatch}) else { return }
  if individual {
   for i in snapshot.batches[b].documents.indices where selection.contains(snapshot.batches[b].documents[i].id) && !snapshot.batches[b].documents[i].state.locked { snapshot.batches[b].documents[i].settingsOverride = settings }
  } else {
   let old = snapshot.batches[b].settings
   for i in snapshot.batches[b].documents.indices where snapshot.batches[b].documents[i].state.locked && snapshot.batches[b].documents[i].settingsOverride == nil { snapshot.batches[b].documents[i].settingsOverride = old }
   snapshot.batches[b].settings = settings
  }
  persist(); refreshPreview()
 }
 func clearOverrides() {
  guard let bid = selectedBatch else { return }
  for id in selection { update(bid,id) { if !$0.state.locked { $0.settingsOverride = nil } } }; persist(); refreshPreview()
 }
 func setConversion(_ options: ConversionOptions) {
  guard let bid = selectedBatch else { return }
  for id in selection { update(bid,id) { if !$0.state.locked && $0.state != .preparing { $0.conversion = options; $0.state = .preparing; $0.pdfPath = nil; $0.error = nil } } }; persist(); startPreparing()
 }
 func refreshPreview() {
  previewTask?.cancel(); previewWork?.cancel(); previewError = nil
  guard let doc = selectedItem, let path = doc.pdfPath else { previewURL = nil; return }
  let setting = settings(for:doc)
  previewBusy = true
  previewTask = Task {
   do {
    try await Task.sleep(nanoseconds: 200_000_000)
    let dest = URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("preview-\(UUID().uuidString).pdf")
    let work = Task.detached { try PDFComposer.compose(source:URL(fileURLWithPath:path), destination:dest, settings:setting) }
    previewWork = work
    _ = try await work.value
    if Task.isCancelled { try? FileManager.default.removeItem(at:dest); return }
    let old = previewURL; previewURL = dest; previewBusy = false
    if let old, old.lastPathComponent.hasPrefix("preview-") { try? FileManager.default.removeItem(at:old) }
   } catch { if !Task.isCancelled { previewError = error.localizedDescription; previewBusy = false } }
  }
 }
 func move(from: IndexSet, to: Int) {
  guard !running, section == "批次", search.isEmpty, let b = snapshot.batches.firstIndex(where: {$0.id == selectedBatch}) else { return }
  snapshot.batches[b].documents.move(fromOffsets:from,toOffset:to); persist()
 }
 var canDeleteSelected: Bool {
  guard let bid = selectedBatch else { return false }
  return canDeleteDocuments(batchID:bid,ids:selection)
 }
 private func deletable(_ document: DocumentItem) -> Bool {
  [.ready,.completed,.failed,.cancelled].contains(document.state) && activeConversionID != document.id
 }
 func canDeleteDocuments(batchID: UUID, ids: Set<UUID>) -> Bool {
  guard store != nil, !running, !preparing, importCounts.isEmpty, !ids.isEmpty,
        let batch = snapshot.batches.first(where: { $0.id == batchID }) else { return false }
  let documents = batch.documents.filter { ids.contains($0.id) }
  return documents.count == ids.count && documents.allSatisfy(deletable)
 }
 func canDeleteBatch(_ id: UUID) -> Bool {
  guard store != nil, !running, !preparing, importCounts.isEmpty,
        let batch = snapshot.batches.first(where: { $0.id == id }) else { return false }
  return batch.documents.allSatisfy(deletable)
 }
 private func saveDeletion(_ candidate: AppSnapshot) -> Bool {
  do {
   guard let store else { throw PrintFailure("数据目录不可用") }
   try store.save(candidate)
   snapshot = candidate
   return true
  } catch { message = "未删除任何记录：\(error.localizedDescription)"; return false }
 }
 @discardableResult func deleteDocuments(batchID: UUID, ids: Set<UUID>) -> Bool {
  guard canDeleteDocuments(batchID:batchID,ids:ids),
        let b = snapshot.batches.firstIndex(where: { $0.id == batchID }) else {
   message = "请选择已停止的任务。转换、输出或导入进行中时请稍后再删；系统排队和需核实的任务必须先确认状态。"
   return false
  }
  let removed = snapshot.batches[b].documents.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset,$0.element) }
  var candidate = snapshot
  candidate.batches[b].documents.removeAll { ids.contains($0.id) }
  guard saveDeletion(candidate) else { return false }
  lastDeletion = .documents(batchID,removed)
  deletionNotice = "已删除 \(removed.count) 个任务"
  for id in ids { passwords.removeValue(forKey:id); cancelled.remove(id) }
  if selectedBatch == batchID { selection.subtract(ids); refreshPreview() }
  return true
 }
 @discardableResult func deleteBatch(_ id: UUID) -> Bool {
  guard canDeleteBatch(id), let index = snapshot.batches.firstIndex(where: { $0.id == id }) else {
   message = "这个批次还有转换、输出或状态待核实的任务，请先确认任务已停止。"
   return false
  }
  let removed = snapshot.batches[index]
  var candidate = snapshot; candidate.batches.remove(at:index)
  guard saveDeletion(candidate) else { return false }
  lastDeletion = .batch(index,removed); deletionNotice = "已删除批次“\(removed.name)”"
  for item in removed.documents { passwords.removeValue(forKey:item.id); cancelled.remove(item.id) }
  if selectedBatch == id { selectedBatch = snapshot.batches.first?.id; selection = []; refreshPreview() }
  return true
 }
 func undoDeletion() {
  guard let record = lastDeletion else { return }
  guard !running, !preparing, importCounts.isEmpty else { message = "请等待当前操作停止后撤销删除。"; return }
  var candidate = snapshot
  let restoredBatch: UUID; let restoredIDs: Set<UUID>
  switch record {
  case .documents(let bid, let records):
   guard let b = candidate.batches.firstIndex(where: { $0.id == bid }) else { message = "原批次已不存在，无法撤销。"; return }
   for (index,document) in records.sorted(by: { $0.0 < $1.0 }) {
    if !candidate.batches[b].documents.contains(where: { $0.id == document.id }) { candidate.batches[b].documents.insert(document,at:min(index,candidate.batches[b].documents.count)) }
   }
   restoredBatch = bid; restoredIDs = Set(records.map { $0.1.id })
  case .batch(let index, let batch):
   guard !candidate.batches.contains(where: { $0.id == batch.id }) else { return }
   candidate.batches.insert(batch,at:min(index,candidate.batches.count)); restoredBatch = batch.id; restoredIDs = []
  }
  guard saveDeletion(candidate) else { return }
  selectedBatch = restoredBatch; selection = restoredIDs; section = "批次"
  lastDeletion = nil; deletionNotice = nil; refreshPreview()
 }
 private var undoProtectedFolders: Set<String> {
  guard let lastDeletion else { return [] }
  let documents: [DocumentItem]
  switch lastDeletion { case .documents(_,let records): documents = records.map { $0.1 }; case .batch(_,let batch): documents = batch.documents }
  return Set(documents.map { URL(fileURLWithPath:$0.sourcePath).deletingLastPathComponent().path })
 }
 func startOutput() {
  guard !running, let batch = currentBatch else { return }
  guard !batch.documents.contains(where: { $0.state == .preparing }) else { message = "请等待本批次转换完成后再开始输出。"; return }
  let docs = batch.documents.filter { $0.state == .ready }
  guard !docs.isEmpty else { message = "没有待执行文件。请等待转换完成，或选择失败任务重试。"; return }
  var dir: URL?
  if docs.contains(where: { settings(for:$0,batch:batch).target.isPDF }) {
   let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "保存到此文件夹"; panel.message = "每个文件生成一个 PDF，已有文件不会被覆盖"
   if !snapshot.preferences.lastExportDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath:snapshot.preferences.lastExportDirectory) }
   guard panel.runModal() == .OK, let url = panel.url else { return }; dir = url; snapshot.preferences.lastExportDirectory = url.path
  }
  guard persist() else { return }
  run(batchID:batch.id, ids:docs.map(\.id), exportDirectory:dir)
 }
 func run(batchID: UUID, ids: [UUID], exportDirectory: URL?) {
  running = true; paused = false; cancelled.subtract(ids)
  queueTask = Task {
   defer { running = false; queueTask = nil }
   for id in ids {
    while paused && !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
    if Task.isCancelled { break }
    guard !cancelled.contains(id), let doc = item(batchID,id), doc.state == .ready, let path = doc.pdfPath, let batch = snapshot.batches.first(where: {$0.id == batchID}) else { continue }
    let setting = settings(for:doc,batch:batch)
    update(batchID,id) { $0.state = .processing; $0.settingsOverride = setting }
    guard persist() else { break }
    do {
     if !setting.target.isPDF { try await Task.detached { [backend] in try backend.validate(settings:setting) }.value }
     let out = URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("output-\(UUID().uuidString).pdf")
     _ = try await Task.detached { try PDFComposer.compose(source:URL(fileURLWithPath:path), destination:out, settings:setting) }.value
     if cancelled.contains(id) { continue }
     var attempt = OutputAttempt(settings:setting)
     if setting.target.isPDF {
      guard let exportDirectory else { throw PrintFailure("没有选择 PDF 保存目录") }
      attempt.outputPath = FileServices.availableOutput(name:doc.name,directory:exportDirectory).path
      attempt.checksum = try await Task.detached { try FileServices.sha256(out) }.value
     }
     if cancelled.contains(id) { continue }
     attempt.events.append(StateEvent(message:"执行记录已保存，准备输出"))
     update(batchID,id) { $0.composedPath = out.path; $0.settingsOverride = setting; $0.attempts.append(attempt); $0.state = .submitting; $0.error = nil }
     guard persist() else { break }
     if setting.target.isPDF {
      let destination = URL(fileURLWithPath:attempt.outputPath!)
      let aid = attempt.id
      let export = Task.detached { try FileServices.exportPDF(source:out,destination:destination,attempt:aid) }
      activeExport = export; activeExportID = id
      defer { activeExport = nil; activeExportID = nil }
      let digest = try await export.value
      update(batchID,id) { $0.state = .completed; $0.attempts[$0.attempts.count-1].checksum = digest; $0.attempts[$0.attempts.count-1].state = .completed; $0.attempts[$0.attempts.count-1].events.append(StateEvent(message:"已保存 PDF：\(destination.lastPathComponent)")) }
      guard persist() else { break }
     } else {
      let aid = attempt.id
      let jobID: Int
      do { jobID = try await Task.detached { [backend] in try backend.submit(pdf:out,settings:setting,attemptID:aid) }.value }
      catch {
       update(batchID,id) { $0.state = .needsReview; $0.error = "提交结果不明：\(error.localizedDescription)。核实打印机后再决定是否重打。"; $0.attempts[$0.attempts.count-1].state = .needsReview }
       persist(); paused = true; continue
      }
      update(batchID,id) { $0.state = .queued; $0.attempts[$0.attempts.count-1].systemJobID = jobID; $0.attempts[$0.attempts.count-1].state = .queued }
      guard persist() else { break }
      await track(batchID:batchID,itemID:id,settings:setting,jobID:jobID)
      if item(batchID,id)?.state == .needsReview { paused = true }
     }
    } catch is CancellationError {
     update(batchID,id) { $0.state = .cancelled; if !$0.attempts.isEmpty { $0.attempts[$0.attempts.count-1].state = .cancelled; $0.attempts[$0.attempts.count-1].events.append(StateEvent(message:"已取消保存，未安装最终输出文件")) } }; persist()
    } catch {
     if cancelled.contains(id) { continue }
     update(batchID,id) { $0.state = .failed; $0.error = error.localizedDescription; if !$0.attempts.isEmpty { $0.attempts[$0.attempts.count-1].state = .failed; $0.attempts[$0.attempts.count-1].events.append(StateEvent(message:error.localizedDescription)) } }
     guard persist() else { break }
    }
   }
  }
 }
 func track(batchID:UUID,itemID:UUID,settings:OutputSettings,jobID:Int) async {
  guard case .printer(let name) = settings.target else { return }
  while !Task.isCancelled {
   let status = await Task.detached { [backend] in backend.status(printer:name,jobID:jobID) }.value
   var done = false
   update(batchID,itemID) { doc in
    let next: JobState
    switch status {
    case .pending: next = .queued
    case .processing: next = .processing
    case .completed: next = .completed; done = true
    case .cancelled: next = .cancelled; done = true
    case .failed(let error): next = .failed; doc.error = error; done = true
    case .unknown: next = .needsReview; doc.error = "无法核实系统任务状态，请检查打印机后决定是否重打"; done = true
    }
    if doc.state != next { doc.state = next; if !doc.attempts.isEmpty { doc.attempts[doc.attempts.count-1].state = next; doc.attempts[doc.attempts.count-1].events.append(StateEvent(message: next == .completed ? "系统报告完成（未逐张核实出纸）" : next.rawValue)) } }
   }
   guard persist() else { break }
   if done { break }
   try? await Task.sleep(nanoseconds: 2_000_000_000)
  }
 }
 func cancelSelected() {
  guard let bid = selectedBatch else { return }
  for id in selection {
   guard let doc = item(bid,id), !doc.state.terminal else { continue }
   if doc.state == .submitting {
    if activeExportID == id { activeExport?.cancel() }
    else { message = "当前文件正在提交，请等待提交结果后再取消。" }
    continue
   }
   cancelled.insert(id)
   if activeConversionID == id { activeConversion?.cancel() }
   if let attempt = doc.attempts.last, let jid = attempt.systemJobID, case .printer(let p) = attempt.settings.target {
    Task { do { try await Task.detached { [backend] in try backend.cancel(printer:p,jobID:jid) }.value } catch { message = error.localizedDescription } }
   } else if doc.state != .needsReview {
    update(bid,id) { $0.state = .cancelled }; persist()
   }
  }
 }
 func retrySelected() {
  guard let bid = selectedBatch, let b = snapshot.batches.firstIndex(where: {$0.id == bid}) else { return }
  let docs = snapshot.batches[b].documents.filter { selection.contains($0.id) && ($0.state.terminal || $0.state == .needsReview) }
  for doc in docs {
   if activeConversionID == doc.id { message = "正在停止转换，请稍后重试。"; continue }
   guard FileManager.default.fileExists(atPath:doc.sourcePath), doc.pdfPath == nil || FileManager.default.fileExists(atPath:doc.pdfPath!) else { message = "内部缓存已过期，请重新导入原文件。已导出的 PDF 不受影响。"; continue }
   if !doc.attempts.isEmpty {
    let alert = NSAlert(); alert.messageText = "再次输出“\(doc.name)”"; alert.informativeText = "原任务可能已经输出。新任务保留原页码范围，你可以在开始前修改页码，避免重复打印。"; alert.addButton(withTitle:"创建重打任务"); alert.addButton(withTitle:"取消")
    if alert.runModal() != .alertFirstButtonReturn { continue }
    var copy = doc; copy.id = UUID(); copy.created = Date(); copy.attempts = []; copy.state = copy.pdfPath == nil ? .preparing : .ready; copy.error = nil
    snapshot.batches[b].documents.append(copy); selection = [copy.id]
   } else { update(bid,doc.id) { $0.state = .preparing; $0.error = nil }; cancelled.remove(doc.id) }
  }
  persist(); startPreparing(); refreshPreview()
 }
 func recover() {
  for bi in snapshot.batches.indices {
   for di in snapshot.batches[bi].documents.indices {
    let doc = snapshot.batches[bi].documents[di]
    guard [.submitting,.queued,.processing].contains(doc.state) else { continue }
    var next: JobState = doc.attempts.isEmpty ? .ready : .needsReview
    if let a = doc.attempts.last {
     if a.settings.target.isPDF, let path = a.outputPath, let hash = a.checksum {
      next = (try? FileServices.sha256(URL(fileURLWithPath:path))) == hash ? .completed : .needsReview
     } else if a.systemJobID != nil { next = .queued }
    }
    snapshot.batches[bi].documents[di].state = next
    if !snapshot.batches[bi].documents[di].attempts.isEmpty { snapshot.batches[bi].documents[di].attempts[snapshot.batches[bi].documents[di].attempts.count-1].state = next }
   }
  }
  persist()
  for batch in snapshot.batches {
   for doc in batch.documents where [.queued,.needsReview].contains(doc.state) {
    guard let a = doc.attempts.last, case .printer(let p) = a.settings.target else { continue }
    recoveryTasks.append(Task {
     let found: Int?
     if let existing = a.systemJobID { found = existing } else { found = try? await Task.detached { [backend] in try backend.findJob(printer:p,attemptID:a.id) }.value }
     if let jid = found {
      update(batch.id,doc.id) { $0.attempts[$0.attempts.count-1].systemJobID = jid }; persist()
      await track(batchID:batch.id,itemID:doc.id,settings:a.settings,jobID:jid)
     }
    })
   }
  }
  startPreparing()
 }
 func saveTemplate(name: String) { guard let batch = currentBatch, !name.trimmingCharacters(in:.whitespaces).isEmpty else { return }; snapshot.templates.append(PrintTemplate(name:name,settings:batch.settings)); persist() }
 func exportLog() {
  let panel = NSSavePanel(); panel.nameFieldStringValue = "批量打印-日志.json"
  if panel.runModal() == .OK, let url = panel.url {
   do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; let data = try encoder.encode(snapshot.batches); try data.write(to:url,options:.atomic) } catch { message = error.localizedDescription }
  }
 }
 func cleanup() {
  guard !running && !preparing && importCounts.isEmpty, let store else { message = "请等待队列停止后清理"; return }
  let cacheCutoff = Date().addingTimeInterval(-Double(snapshot.preferences.cacheDays)*86400)
  let historyCutoff = Date().addingTimeInterval(-Double(snapshot.preferences.historyDays)*86400)
  // Paths may be shared by history retry items; delete only when every reference is inactive and old.
  var protectedFolders = undoProtectedFolders
  for b in snapshot.batches { for d in b.documents where !d.state.terminal || d.created > cacheCutoff { protectedFolders.insert(URL(fileURLWithPath:d.sourcePath).deletingLastPathComponent().path) } }
  do {
   for folder in try FileManager.default.contentsOfDirectory(at:store.files,includingPropertiesForKeys:nil) where !protectedFolders.contains(folder.path) {
    let references = snapshot.batches.flatMap(\.documents).filter { URL(fileURLWithPath:$0.sourcePath).deletingLastPathComponent() == folder }
    if !references.isEmpty && references.allSatisfy({$0.state.terminal && $0.created < cacheCutoff}) { try FileManager.default.removeItem(at:folder) }
    else if references.isEmpty, let created = try folder.resourceValues(forKeys:[.creationDateKey]).creationDate, created < cacheCutoff { try FileManager.default.removeItem(at:folder) }
   }
   for b in snapshot.batches.indices { snapshot.batches[b].documents.removeAll { $0.state.terminal && $0.created < historyCutoff } }
   persist(); message = "已清理过期内部缓存和历史，用户导出的 PDF 未被删除。"
  } catch { message = "清理失败：\(error.localizedDescription)" }
 }
}
