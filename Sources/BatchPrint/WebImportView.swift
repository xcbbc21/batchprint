import SwiftUI
import WebKit
import AppKit

@MainActor final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate {
 let webView = WKWebView(frame:.zero)
 @Published var address = "https://"
 @Published var loading = false
 @Published var loaded = false
 @Published var error: String?
 override init() { super.init(); webView.navigationDelegate = self }
 func navigate() {
  guard let url = URL(string:address), let scheme = url.scheme?.lowercased(), ["https","http"].contains(scheme), url.host != nil else { error = "请输入完整的 http 或 https 网页地址"; return }
  error = nil; loaded = false; loading = true; webView.load(URLRequest(url:url,timeoutInterval:60))
 }
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { loading = false; loaded = true; address = webView.url?.absoluteString ?? address }
 func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) { loading = false; self.error = error.localizedDescription }
 func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) { loading = false; self.error = error.localizedDescription }
}
struct BrowserView:NSViewRepresentable {
 let session:BrowserSession
 func makeNSView(context:Context)->WKWebView { session.webView }
 func updateNSView(_ view:WKWebView,context:Context) {}
}
struct WebImportView:View {
 @EnvironmentObject var model:AppModel; @Environment(\.dismiss) var dismiss
 @StateObject private var session = BrowserSession()
 @State private var saving = false
 var body:some View {
  VStack(spacing:12) {
   HStack { Text("添加网页").font(.title2.bold()); Spacer(); Button("关闭") { session.webView.stopLoading(); dismiss() } }
   HStack { TextField("https://example.com",text:$session.address).textFieldStyle(.roundedBorder).onSubmit { session.navigate() }; Button("打开") { session.navigate() }; if session.loading { ProgressView().controlSize(.small) } }
   Text("可在下方网页中手动登录；确认内容加载完整后保存快照。不会读取其他浏览器的登录信息。").font(.caption).foregroundStyle(.secondary)
   if let error = session.error { Text(error).foregroundStyle(.red) }
   BrowserView(session:session).frame(minWidth:800,minHeight:500)
   HStack { Text("网页将按纸张分页，再进入批次预览。").font(.caption).foregroundStyle(.secondary); Spacer(); Button(saving ? "正在生成…" : "将此网页加入批次") { save() }.buttonStyle(.borderedProminent).disabled(!session.loaded || session.loading || saving) }
  }.padding(18)
 }
 func save() {
  guard let root = model.store?.root else { return }
  saving = true
  Task { @MainActor in
   do {
    let temp = root.appendingPathComponent("WebImports",isDirectory:true)
    try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
    let title = (session.webView.title ?? "网页").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:":",with:"_")
    let url = temp.appendingPathComponent("\(String(title.prefix(80)))-\(UUID().uuidString.prefix(6)).pdf")
    try await WebRenderer.save(webView:session.webView,destination:url)
    model.importURLs([url]); saving = false; dismiss()
   } catch { session.error = error.localizedDescription; saving = false }
  }
 }
}
