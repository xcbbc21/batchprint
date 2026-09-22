import AppKit
import WebKit
import PDFKit

@MainActor final class WebRenderer: NSObject, WKNavigationDelegate {
 private var continuation: CheckedContinuation<Void, Error>?
 private var webView: WKWebView?
 func render(html: String, baseURL: URL?, destination: URL, timeout: Double) async throws {
  let deadline = Date().addingTimeInterval(max(1, timeout))
  let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
  let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = web
  webView = web; web.navigationDelegate = self
  let timer = Task { try await Task.sleep(for: .seconds(max(1, timeout))); self.finish(PrintFailure("网页加载超时")) }
  defer { timer.cancel(); web.stopLoading(); window.contentView = nil; window.close(); webView = nil }
  try await withTaskCancellationHandler(operation: {
   try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
    continuation = c; web.loadHTMLString(html, baseURL: baseURL)
   }
  }, onCancel: { Task { @MainActor in self.finish(CancellationError()) } })
  try Task.checkCancellation(); try await Self.save(webView: web, destination: destination, timeout: max(0.01, deadline.timeIntervalSinceNow))
 }
 static func save(webView: WKWebView, destination: URL, timeout: Double = 180) async throws {
  try Task.checkCancellation()
  let deadline = Date().addingTimeInterval(max(1, timeout))
  // Native WebKit print views can report an unbounded page range when saved without
  // a print panel. Capture finite vector PDF slices at measured text-line boundaries.
  let script = """
  (() => {
   const rects = []; let nodes = 0;
   const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
   let node;
   while ((node = walker.nextNode()) && nodes++ < 100000) {
    if (!node.textContent.trim()) continue;
    const parent = node.parentElement;
    if (!parent || ['SCRIPT','STYLE','NOSCRIPT'].includes(parent.tagName)) continue;
    const range = document.createRange(); range.selectNodeContents(node);
    for (const r of range.getClientRects()) if (r.height > 0 && r.width > 0) rects.push([r.top + scrollY, r.bottom + scrollY]);
   }
   for (const node of document.querySelectorAll('img,svg,canvas,tr,pre,h1,h2,h3,h4,h5,h6')) {
    const r = node.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) {
     let bottom = r.bottom;
     if (/^H[1-6]$/.test(node.tagName) && node.nextElementSibling) bottom = Math.max(bottom, node.nextElementSibling.getBoundingClientRect().bottom);
     rects.push([r.top + scrollY, bottom + scrollY]);
    }
   }
   const root = document.documentElement, body = document.body;
   const breaks = [];
   for (const node of document.querySelectorAll('*')) {
    const style = getComputedStyle(node), r = node.getBoundingClientRect();
    if (['page','always','left','right'].includes(style.breakBefore)) breaks.push(r.top + scrollY);
    if (['page','always','left','right'].includes(style.breakAfter)) breaks.push(r.bottom + scrollY);
   }
   return {width: Math.max(root.scrollWidth, body ? body.scrollWidth : 0, innerWidth),
    height: Math.max(root.scrollHeight, body ? body.scrollHeight : 0), rects, breaks};
  })()
  """
  guard let metrics = try await webView.evaluateJavaScript(script) as? [String: Any],
        let width = metrics["width"] as? Double, let height = metrics["height"] as? Double,
        width.isFinite, height.isFinite, width > 0, height > 0, width <= 20000, height <= 2_000_000 else {
   throw PrintFailure("网页尺寸无法读取或超过可打印范围")
  }
  let lines = (metrics["rects"] as? [[Double]] ?? []).filter { $0.count == 2 && $0[0].isFinite && $0[1].isFinite }
  let forced = (metrics["breaks"] as? [Double] ?? []).filter { $0.isFinite }.sorted()
  let pageSize = CGSize(width: 595.276, height: 841.89)
  let margin: CGFloat = 28
  let scale = (pageSize.width - 2 * margin) / width
  let capacity = (pageSize.height - 2 * margin) / scale
  var segments: [(Double, Double)] = [], start = 0.0
  while start < height - 0.5 {
   try Task.checkCancellation()
   guard segments.count < 2000 else { throw PrintFailure("网页超过 2000 页，请缩小内容范围") }
   var end = min(height, start + capacity)
   if let explicit = forced.first(where: { $0 > start + 1 && $0 < end }) { end = explicit }
   // Move a boundary upward until it no longer crosses a normal text line,
   // table row, heading, or image that can fit on a page.
   for _ in 0..<100 {
    let crossing = lines.filter { $0[0] < end - 0.5 && $0[1] > end + 0.5 && $0[1] - $0[0] < capacity && $0[0] > start + 1 }
    guard let earlier = crossing.map({ $0[0] }).min(), earlier < end else { break }
    end = earlier
   }
   guard end > start else { throw PrintFailure("网页分页无法前进") }
   segments.append((start, end)); start = end
  }
  var box = CGRect(origin: .zero, size: pageSize)
  let temporary = destination.deletingLastPathComponent().appendingPathComponent(".web-" + UUID().uuidString + ".pdf")
  defer { try? FileManager.default.removeItem(at: temporary) }
  guard let consumer = CGDataConsumer(url: temporary as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw PrintFailure("网页 PDF 无法创建") }
  do {
   for (top, bottom) in segments {
    try Task.checkCancellation()
    guard Date() < deadline else { throw PrintFailure("网页 PDF 输出超时") }
    let configuration = WKPDFConfiguration()
    configuration.rect = CGRect(x: 0, y: top, width: width, height: bottom-top)
    let data = try await webView.pdf(configuration: configuration)
    guard let pdf = PDFDocument(data: data), let page = pdf.page(at: 0)?.pageRef else { throw PrintFailure("网页分页渲染失败") }
    context.beginPDFPage(nil)
    let target = CGRect(x: margin, y: pageSize.height-margin-(bottom-top)*scale, width: width*scale, height: (bottom-top)*scale)
    context.saveGState(); context.clip(to: target)
    context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(page)
    context.restoreGState(); context.endPDFPage()
   }
   context.closePDF()
  } catch { context.closePDF(); throw error }
  guard let result = PDFDocument(url: temporary), result.pageCount == segments.count else { throw PrintFailure("网页分页结果校验失败") }
  if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
  try FileManager.default.moveItem(at: temporary, to: destination)
 }
 func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
 func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
 func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
 private func finish(_ error: Error?) { guard let c = continuation else { return }; continuation = nil; if let error { c.resume(throwing: error) } else { c.resume() } }
}
