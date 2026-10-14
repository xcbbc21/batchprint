import SwiftUI
import AppKit

final class ApplicationDelegate:NSObject, NSApplicationDelegate {
 weak var model: AppModel?
 @MainActor func application(_ application:NSApplication, open urls:[URL]) { model?.importURLs(urls) }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { .terminateNow }
}
struct BatchPrintApp:App {
 @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
 @StateObject private var model = AppModel()
 var body:some Scene {
  WindowGroup("批量打印") { ContentView().environmentObject(model).frame(minWidth:1050,minHeight:720).onAppear { delegate.model = model } }.defaultSize(width:1280,height:860)
   .commands {
    CommandGroup(replacing:.newItem) { Button("新建任务") { model.newBatch() }.keyboardShortcut("n"); Button("添加文件…") { model.chooseFiles() }.keyboardShortcut("o"); Button("添加网页…") { model.webVisible = true }.keyboardShortcut("l") }
    CommandGroup(replacing:.appSettings) { Button("设置…") { model.settingsVisible = true }.keyboardShortcut(",") }
   }
 }
}

@main enum EntryPoint {
 static func main() {
  if let i = CommandLine.arguments.firstIndex(of:"--self-test"), CommandLine.arguments.count > i+1 {
   let directory = URL(fileURLWithPath:CommandLine.arguments[i+1])
   let samples = CommandLine.arguments.firstIndex(of:"--samples").flatMap { CommandLine.arguments.count > $0+1 ? URL(fileURLWithPath:CommandLine.arguments[$0+1]) : nil }
   NSApplication.shared.setActivationPolicy(.prohibited)
   NSApplication.shared.finishLaunching()
   Task { @MainActor in
    do { try await SelfTests.run(directory:directory,sampleDirectory:samples); exit(0) }
    catch { fputs("SELFTEST FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
   }
   RunLoop.main.run()
  } else { BatchPrintApp.main() }
 }
}
