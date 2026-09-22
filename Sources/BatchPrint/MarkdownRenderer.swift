import Foundation

enum MarkdownRenderer {
 static func html(_ text: String) -> String {
  let lines = text.components(separatedBy: .newlines)
  var body = "", code: [String] = [], paragraph: [String] = []
  var fenced = false, list: String? = nil
  func flushParagraph() { if !paragraph.isEmpty { body += "<p>" + inline(paragraph.joined(separator: " ")) + "</p>"; paragraph = [] } }
  func closeList() { if let tag = list { body += "</\(tag)>"; list = nil } }
  var index = 0
  while index < lines.count {
   let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
   if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
    flushParagraph(); closeList()
    if fenced { body += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>"; code = [] }
    fenced.toggle(); index += 1; continue
   }
   if fenced { code.append(line); index += 1; continue }
   if trimmed.isEmpty { flushParagraph(); closeList(); index += 1; continue }
   if index+1 < lines.count, line.contains("|"), isTableDivider(lines[index+1]) {
    flushParagraph(); closeList(); body += "<table><thead><tr>"
    for cell in cells(line) { body += "<th>" + inline(cell) + "</th>" }; body += "</tr></thead><tbody>"; index += 2
    while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
     body += "<tr>"; for cell in cells(lines[index]) { body += "<td>" + inline(cell) + "</td>" }; body += "</tr>"; index += 1
    }
    body += "</tbody></table>"; continue
   }
   let hashes = trimmed.prefix(while: { $0 == "#" }).count
   if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
    flushParagraph(); closeList(); body += "<h\(hashes)>" + inline(String(trimmed.dropFirst(hashes+1))) + "</h\(hashes)>"
   } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
    flushParagraph(); if list != "ul" { closeList(); body += "<ul>"; list = "ul" }; body += "<li>" + inline(String(trimmed.dropFirst(2))) + "</li>"
   } else if let range = trimmed.range(of: "^[0-9]+[.)]\\s+", options: .regularExpression) {
    flushParagraph(); if list != "ol" { closeList(); body += "<ol>"; list = "ol" }; body += "<li>" + inline(String(trimmed[range.upperBound...])) + "</li>"
   } else if trimmed.hasPrefix("> ") {
    flushParagraph(); closeList(); body += "<blockquote>" + inline(String(trimmed.dropFirst(2))) + "</blockquote>"
   } else if ["---", "***", "___"].contains(trimmed) { flushParagraph(); closeList(); body += "<hr>" }
   else { closeList(); paragraph.append(line) }
   index += 1
  }
  flushParagraph(); closeList()
  if fenced { body += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>" }
  return "<!doctype html><meta charset='utf-8'><style>body{font:11pt -apple-system;line-height:1.5;overflow-wrap:anywhere}h1,h2,h3,h4,h5,h6{page-break-after:avoid}table{border-collapse:collapse;width:100%;font-size:10pt}th,td{border:1px solid #aaa;padding:5px;vertical-align:top}thead{display:table-header-group}tr{page-break-inside:avoid}pre{white-space:pre-wrap;background:#f3f3f3;padding:8px}blockquote{border-left:3px solid #aaa;padding-left:10px;color:#444}img{max-width:100%}</style>" + body
 }
 static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
 private static func inline(_ text: String) -> String {
  let parts = text.components(separatedBy: "`")
  return parts.enumerated().map { index, part in
   var value = escape(part)
   if index % 2 == 1 && index < parts.count - 1 { return "<code>" + value + "</code>" }
   for (pattern, replacement) in [("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"), ("__([^_]+)__", "<strong>$1</strong>"), ("\\*([^*]+)\\*", "<em>$1</em>")] {
    value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
   }
   return (index > 0 && index % 2 == 1 ? "`" : "") + value
  }.joined()
 }

 private static func cells(_ line: String) -> [String] {
  var value = line.trimmingCharacters(in: .whitespaces)
  if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
  return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
 }
 private static func isTableDivider(_ line: String) -> Bool {
  let parts = cells(line)
  return !parts.isEmpty && parts.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
 }
}
