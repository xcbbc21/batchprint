import Foundation

enum WorkbookPrintSettings {
 static func apply(directory: URL, selectedSheets: String, fitColumns: Bool) throws {
  let workbookURL = directory.appendingPathComponent("xl/workbook.xml")
  let document = try XMLDocument(contentsOf: workbookURL)
  let sheets = try document.nodes(forXPath: "//*[local-name()='sheets']/*[local-name()='sheet']").compactMap { $0 as? XMLElement }
  let requested = selectedSheets.replacingOccurrences(of: "，", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  let names = sheets.compactMap { $0.attribute(forName: "name")?.stringValue }
  for name in requested where !names.contains(name) { throw PrintFailure("找不到工作表：\(name)。可用工作表：\(names.joined(separator: "、"))") }
  guard !sheets.isEmpty else { throw PrintFailure("工作簿没有工作表") }
  if !requested.isEmpty {
   var first: Int?
   for (index, sheet) in sheets.enumerated() {
    let visible = requested.contains(sheet.attribute(forName: "name")?.stringValue ?? "")
    set(sheet, "state", visible ? "visible" : "hidden")
    if visible && first == nil { first = index }
   }
   for view in try document.nodes(forXPath: "//*[local-name()='workbookView']").compactMap({ $0 as? XMLElement }) { set(view, "activeTab", String(first ?? 0)) }
  }
  try document.xmlData(options: []).write(to: workbookURL)
  if fitColumns {
   let folder = directory.appendingPathComponent("xl/worksheets")
   for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "xml" {
    try Task.checkCancellation()
    let sheet = try XMLDocument(contentsOf: url)
    guard let root = sheet.rootElement() else { continue }
    let properties: XMLElement
    if let existing = root.elements(forName: "sheetPr").first { properties = existing }
    else { properties = XMLElement(name: "sheetPr"); root.insertChild(properties, at: 0) }
    let setupProperties = properties.elements(forName: "pageSetUpPr").first ?? XMLElement(name: "pageSetUpPr")
    if setupProperties.parent == nil { properties.addChild(setupProperties) }
    set(setupProperties, "fitToPage", "1")
    let setup = root.elements(forName: "pageSetup").first ?? XMLElement(name: "pageSetup")
    if setup.parent == nil {
     // SpreadsheetML requires pageSetup before headerFooter, breaks, drawings and extensions.
     let later = Set(["headerFooter", "rowBreaks", "colBreaks", "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing", "legacyDrawing", "legacyDrawingHF", "picture", "oleObjects", "controls", "webPublishItems", "tableParts", "extLst"])
     let index = root.children?.firstIndex(where: { later.contains($0.localName ?? "") }) ?? root.childCount
     root.insertChild(setup, at: index)
    }
    setup.removeAttribute(forName: "scale"); set(setup, "fitToWidth", "1"); set(setup, "fitToHeight", "0")
    try sheet.xmlData(options: []).write(to: url)
   }
  }
 }
 private static func set(_ element: XMLElement, _ name: String, _ value: String) {
  element.removeAttribute(forName: name); element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
 }
}
