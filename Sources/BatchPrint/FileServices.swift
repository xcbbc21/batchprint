import Foundation
import CryptoKit
import PDFKit
import CSQLite
import Darwin

struct FileServices {
 static func sha256(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
  var hash = SHA256()
  while let chunk = try handle.read(upToCount: 1024*1024), !chunk.isEmpty { hash.update(data: chunk) }
  return hash.finalize().map { String(format:"%02x", $0) }.joined()
 }
 static func ensureSpace(at url: URL, bytes: Int64 = 32*1024*1024) throws {
  let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
  guard let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value > bytes else { throw PrintFailure("磁盘空间不足，请清理空间或更换保存目录") }
 }
 static func importFiles(_ urls: [URL], recursive: Bool) throws -> [URL] {
  var result: [URL] = []
  for url in urls {
   let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
   if values.isSymbolicLink == true { continue }
   if values.isDirectory == true {
    let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: options) {
     var children: [URL] = []
     for case let child as URL in enumerator {
      let v = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if v.isSymbolicLink == true { enumerator.skipDescendants(); continue }
      if v.isRegularFile == true { children.append(child) }
     }
     result += children.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
   } else { result.append(url) }
  }
  return result
 }
 static func snapshot(source: URL, root: URL) throws -> DocumentItem {
  try ensureSpace(at: root, bytes: Int64((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) + 32*1024*1024)
  let hash = ""
  var item = DocumentItem(name: source.lastPathComponent, sourcePath: "", sourceHash: hash)
  let folder = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let dest = folder.appendingPathComponent(source.lastPathComponent)
  try FileManager.default.copyItem(at: source, to: dest)
  item.sourcePath = dest.path; item.sourceHash = try sha256(dest); item.originalURL = source.absoluteString
  // Preserve conventional HTML companion resource folder inside the snapshot.
  if ["html", "htm"].contains(source.pathExtension.lowercased()) {
   for suffix in ["_files", ".files"] {
    let companion = source.deletingPathExtension().appendingPathExtension("unused").deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix)
    if FileManager.default.fileExists(atPath: companion.path) { try FileManager.default.copyItem(at: companion, to: folder.appendingPathComponent(companion.lastPathComponent)) }
   }
  }
  return item
 }
 static func availableOutput(name: String, directory: URL) -> URL {
  let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
  let safe = stem.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
  var n = 0
  while true {
   let suffix = n == 0 ? "" : " (\(n))"
   let url = directory.appendingPathComponent("\(safe)-打印\(suffix).pdf")
   if !FileManager.default.fileExists(atPath: url.path) { return url }; n += 1
  }
 }
 static func exportPDF(source: URL, destination: URL, attempt: UUID) throws -> String {
  try Task.checkCancellation()
  let dir = destination.deletingLastPathComponent()
  let size = Int64((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
  try ensureSpace(at: dir, bytes: size + 4*1024*1024)
  let temp = dir.appendingPathComponent(".batchprint-\(attempt.uuidString).tmp")
  defer { try? FileManager.default.removeItem(at: temp) }
  try FileManager.default.copyItem(at: source, to: temp)
  guard let document = PDFDocument(url: temp), document.pageCount > 0 else { throw PrintFailure("导出 PDF 校验失败") }
  let digest = try sha256(temp)
  let fd = open(temp.path, O_RDONLY); if fd >= 0 { _ = fsync(fd); close(fd) }
  try Task.checkCancellation()
  // Exclusive rename installs atomically without replacing existing files, including external volumes.
  guard renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
   let code = errno
   if code == EEXIST { throw PrintFailure("目标文件已存在，请重试以使用新的文件名") }
   throw PrintFailure("无法保存 PDF：\(String(cString: strerror(code)))")
  }
  return digest
 }
}

final class HistoryStore {
 let root: URL; let files: URL
 private var db: OpaquePointer?
 init(root: URL) throws {
  self.root = root; files = root.appendingPathComponent("Documents", isDirectory: true)
  try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
  guard sqlite3_open(root.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else { throw PrintFailure("无法打开本地历史数据库") }
  try exec("PRAGMA journal_mode=WAL;"); try exec("PRAGMA synchronous=FULL;")
  try exec("CREATE TABLE IF NOT EXISTS app_state (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, payload BLOB NOT NULL);")
 }
 deinit { sqlite3_close(db) }
 private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw PrintFailure("历史记录写入失败：\(String(cString: sqlite3_errmsg(db)))") } }
 func load() throws -> AppSnapshot {
  var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
  guard sqlite3_prepare_v2(db, "SELECT payload FROM app_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw PrintFailure("读取历史失败") }
  let step = sqlite3_step(statement)
  if step == SQLITE_ROW {
   let bytes = sqlite3_column_bytes(statement, 0)
   guard let data = sqlite3_column_blob(statement, 0) else { throw PrintFailure("历史记录为空或损坏") }
   return try JSONDecoder().decode(AppSnapshot.self, from: Data(bytes: data, count: Int(bytes)))
  }
  guard step == SQLITE_DONE else { throw PrintFailure("历史数据库读取失败，已停止启动以保护现有记录") }
  return AppSnapshot()
 }
 func save(_ value: AppSnapshot) throws {
  let data = try JSONEncoder().encode(value)
  var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
  guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO app_state(id, version, payload) VALUES(1,1,?)", -1, &statement, nil) == SQLITE_OK else { throw PrintFailure("无法保存历史") }
  let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  let status = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
  guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw PrintFailure("保存历史失败；为防止重复输出，队列已暂停") }
 }
}
