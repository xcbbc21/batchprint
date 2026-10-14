import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
 @EnvironmentObject var model: AppModel
 @State private var batchPendingDeletion: UUID?
 @State private var individual = false
 @State private var templateName = ""
 @State private var password = ""
 @State private var showPassword = false
 @State private var showConversion = false
 @State private var showTemplatePrompt = false
 var body: some View {
  NavigationSplitView {
   VStack(alignment:.leading,spacing:16) {
    HStack { Image(systemName:"printer.fill").font(.largeTitle).foregroundStyle(.teal); VStack(alignment:.leading) { Text("批量打印").font(.title2.bold()); Text("整理 · 预览 · 输出").foregroundStyle(.secondary).font(.caption) } }.padding(.top,12)
    List {
     Section("工作区") { ForEach(["新建任务","进行中","历史任务"], id:\.self) { name in Button { model.showSection(name) } label: { Label(name,systemImage:icon(name)).foregroundStyle(model.section == name ? Color.accentColor : Color.primary) }.buttonStyle(.plain).padding(.vertical,3) } }
     Section("打印模板") { ForEach(model.snapshot.templates) { template in HStack { Button(template.name) { model.newBatch(template:template) }.buttonStyle(.plain); Spacer(); Button { model.snapshot.templates.removeAll {$0.id == template.id}; model.persist() } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).help("删除模板") } } }
    }.listStyle(.sidebar)
    Button { batchPendingDeletion = model.selectedBatch } label: { Label("删除当前任务",systemImage:"trash") }.buttonStyle(.plain).disabled(model.selectedBatch.map { !model.canDeleteBatch($0) } ?? true)
    Button { model.settingsVisible = true } label: { Label("设置与依赖",systemImage:"gearshape") }.buttonStyle(.plain).padding(.bottom,8)
   }.padding(.horizontal,12).navigationSplitViewColumnWidth(min:190,ideal:220,max:280)
  } content: {
   VStack(spacing:0) {
    HStack { VStack(alignment:.leading,spacing:4) { Text(model.section).font(.title2.bold()); Text(sectionSubtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); if model.preparing { ProgressView().controlSize(.small); Text("转换中").font(.caption) } }.padding(16)
    HStack { Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField("搜索文件",text:$model.search).textFieldStyle(.plain) }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8)).padding(.horizontal,16).padding(.bottom,10)
    if model.visibleDocuments.isEmpty {
     Spacer(); Image(systemName:model.section == "历史任务" ? "clock.arrow.circlepath" : "doc.on.doc").font(.system(size:46,weight:.light)).foregroundStyle(.teal); Text(model.search.isEmpty ? (model.section == "历史任务" ? "暂无历史任务" : model.section == "进行中" ? "暂无进行中的任务" : "将文件拖到这里") : "没有匹配的文件").font(.title3).padding(.top,12); Text(model.section == "历史任务" ? "任务的成功、失败与取消记录会显示在这里" : "PDF、Office、图片、网页与文本").font(.caption).foregroundStyle(.secondary); if model.section != "历史任务" { Button("添加文件") { model.chooseFiles() }.padding(.top,12) }; Spacer()
    } else {
     List(selection:Binding(get:{ model.selection },set:{ model.selectDocuments($0) })) {
      ForEach(model.visibleBatches) { batch in
       Section {
      ForEach(model.visibleDocuments(in:batch)) { doc in
       HStack(alignment:.top,spacing:10) {
        Image(systemName:doc.state == .failed ? "exclamationmark.triangle.fill" : "doc.richtext").foregroundStyle(stateColor(doc.state)).font(.title2).frame(width:26)
        VStack(alignment:.leading,spacing:5) { Text(doc.name).lineLimit(2); HStack { Text(doc.pageCount > 0 ? "\(doc.pageCount) 页" : doc.name.split(separator:".").last.map(String.init)?.uppercased() ?? "文件"); Text("·"); Text(model.settings(for:doc).target.label).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
         if let error = doc.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
        Spacer(minLength:4); Text(statusLabel(doc)).font(.caption).foregroundStyle(stateColor(doc.state)).padding(.horizontal,7).padding(.vertical,4).background(stateColor(doc.state).opacity(0.09),in:Capsule())
       }.padding(.vertical,7).tag(doc.id)
      }.onMove { model.move(from:$0,to:$1) }
       } header: {
        VStack(alignment:.leading,spacing:3) { Text(batch.name); if model.section == "历史任务" { Text(historySummary(batch.documents)).font(.caption).foregroundStyle(.secondary) } }
       }
      }
     }.listStyle(.inset).contextMenu(forSelectionType:UUID.self) { ids in
      Button("再次输出 / 重试") { model.selectDocuments(ids); model.retrySelected() }.disabled(ids.isEmpty)
      Button("取消所选任务") { model.selectDocuments(ids); model.cancelSelected() }.disabled(ids.isEmpty)
      Button("输入 PDF 密码") { model.selectDocuments(ids); showPassword = true }.disabled(ids.count != 1)
      Divider()
      Button("删除任务",role:.destructive) { model.selectDocuments(ids); deleteSelected() }.disabled(model.batch(containing:ids).map { !model.canDeleteDocuments(batchID:$0.id,ids:ids) } ?? true)
     }.onDeleteCommand { deleteSelected() }
    }
    Divider()
    if let notice = model.deletionNotice {
     HStack { Text(notice).font(.caption); Spacer(); Button("撤销") { model.undoDeletion() } }.padding(10).background(Color.teal.opacity(0.08))
    }
    HStack { Button { deleteSelected() } label: { Label("删除任务",systemImage:"trash") }.disabled(!model.canDeleteSelected); Spacer() }.padding(.horizontal,12).padding(.top,8)
    HStack { Text(model.outputSummary).font(.caption).foregroundStyle(.secondary); Spacer(); Menu { Button("导出日志") { model.exportLog() }; Button("再次输出 / 重试") { model.retrySelected() }; Button("取消所选任务") { model.cancelSelected() } } label: { Image(systemName:"ellipsis.circle") }.menuStyle(.borderlessButton).frame(width:25) }.padding(12)
   }.navigationSplitViewColumnWidth(min:300,ideal:380,max:600)
   .onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
    Task { @MainActor in
     var urls:[URL] = []
     for provider in providers { let url:URL? = await withCheckedContinuation { continuation in _ = provider.loadObject(ofClass:URL.self) { url,_ in continuation.resume(returning:url) } }; if let url { urls.append(url) } }
     model.importURLs(urls)
    }; return true
   }
  } detail: {
   VStack(spacing:0) {
    HStack { Text("输出预览").font(.headline); Spacer(); if model.previewBusy { ProgressView().controlSize(.small) }; Text("排版结果").font(.caption).foregroundStyle(.secondary) }.padding(14)
    if let error = model.previewError { Text(error).foregroundStyle(.red).padding() }
    if let url = model.previewURL { PDFPreview(url:url).frame(minHeight:180) }
    else { VStack(spacing:8) { Image(systemName:"doc.text.magnifyingglass").font(.largeTitle); Text("选择文件以查看输出效果").font(.callout) }.foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.underPageBackgroundColor)) }
    Divider()
    ScrollView {
     VStack(alignment:.leading,spacing:12) {
      if model.section != "历史任务" {
      Picker("设置范围",selection:$individual) { Text("整个任务").tag(false); Text("所选文件 (\(model.selection.count))").tag(true) }.pickerStyle(.segmented)
      OutputSettingsView(settings:settingsBinding,printers:model.printers,capabilities:model.capabilities).disabled(individual && (model.selectedItem == nil || model.selectedItem?.state.locked == true))
      if individual { Button("清除所选文件覆盖，继承任务设置") { model.clearOverrides() }.disabled(model.selectedItem?.state.locked == true) }
      HStack {
       Button("转换选项") { showConversion = true }.disabled(model.selectedItem == nil || model.selectedItem?.state.locked == true || model.selectedItem?.state == .preparing)
       Button("PDF 密码") { showPassword = true }.disabled(model.selectedItem == nil || model.selectedItem?.state.locked == true)
       Spacer()
       Button("保存模板") { templateName = "模板 \(model.snapshot.templates.count+1)"; showTemplatePrompt = true }
      }
      }
      if let doc = model.selectedItem {
       ForEach(doc.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
       if model.section == "历史任务" {
        Divider(); Text("执行记录").font(.headline)
        if let error = doc.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        if doc.attempts.isEmpty {
         Text(doc.created.formatted(date:.numeric,time:.shortened)).font(.caption).foregroundStyle(.secondary)
         Text(statusLabel(doc)).foregroundStyle(stateColor(doc.state))
        } else {
         ForEach(Array(doc.attempts.reversed())) { attempt in AttemptHistoryView(attempt:attempt) }
        }
       } else if let attempt = doc.attempts.last {
        Divider(); Text("最近执行").font(.caption.bold())
        ForEach(attempt.events.suffix(4)) { event in Text("\(event.date.formatted(date:.omitted,time:.shortened))  \(event.message)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        if let path = attempt.outputPath, FileManager.default.fileExists(atPath:path) { HStack { Button("打开 PDF") { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) } } }
       }
      }
     }.padding(14)
    }.frame(maxHeight:360)
    Divider()
    HStack {
     if model.running { Button(model.paused ? "继续后续任务" : "暂停后续任务") { model.paused.toggle() }; Text("正在输出").font(.caption).foregroundStyle(.secondary) }
     else { Text("\(readyCount) 个文件待执行").font(.caption).foregroundStyle(.secondary) }
     Spacer(); Button(model.actionTitle) { model.startOutput() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.running || readyCount == 0 || model.currentBatch?.documents.contains(where: { $0.state == .preparing }) == true)
    }.padding(14)
   }.frame(minWidth:380)
  }
  .toolbar {
   ToolbarItemGroup { Button { model.newBatch() } label: { Label("新建任务",systemImage:"plus.square") }; Button { model.chooseFiles() } label: { Label("添加文件",systemImage:"doc.badge.plus") }; Menu { Button("添加文件夹") { model.chooseFiles(folder:true) }; Toggle("包含子文件夹",isOn:$model.recursiveImport) } label: { Label("文件夹",systemImage:"folder.badge.plus") }; Button { model.webVisible = true } label: { Label("网页",systemImage:"globe") } }
  }
  .confirmationDialog("删除这个任务？",isPresented:Binding(get:{batchPendingDeletion != nil},set:{if !$0 { batchPendingDeletion = nil }}),titleVisibility:.visible) {
   Button("删除任务",role:.destructive) { if let id = batchPendingDeletion { _ = model.deleteBatch(id) }; batchPendingDeletion = nil }
   Button("取消",role:.cancel) { batchPendingDeletion = nil }
  } message: { Text("仅删除应用中的任务和文件记录，原文件和已导出的 PDF 保留。可在本次会话撤销最近一次删除。") }
  .onChange(of:model.selection) { _,_ in model.refreshPreview() }
  .sheet(isPresented:$model.settingsVisible) { PreferencesView().environmentObject(model) }
  .sheet(isPresented:$model.webVisible) { WebImportView().environmentObject(model) }
  .sheet(isPresented:$showTemplatePrompt) { VStack(alignment:.leading,spacing:16) { Text("保存任务参数为模板").font(.headline); TextField("模板名称",text:$templateName).textFieldStyle(.roundedBorder); HStack { Button("取消") { showTemplatePrompt = false }; Spacer(); Button("保存") { model.saveTemplate(name:templateName); showTemplatePrompt = false }.disabled(templateName.trimmingCharacters(in:.whitespaces).isEmpty) } }.padding(24).frame(width:360) }
  .sheet(isPresented:$showConversion) { ConversionOptionsView().environmentObject(model) }
  .alert("提示",isPresented:Binding(get:{model.message != nil},set:{if !$0 {model.message = nil}})) { Button("知道了") { model.message = nil } } message: { Text(model.message ?? "") }
  .alert("解锁 PDF",isPresented:$showPassword) { SecureField("密码（仅保留在当前会话）",text:$password); Button("解锁并重试") { model.setPassword(password); password = "" }; Button("取消",role:.cancel) { password = "" } } message: { Text("密码不会写入历史记录或日志。") }
 }
 func deleteSelected() { if model.canDeleteSelected, let bid = model.selectedBatch { _ = model.deleteDocuments(batchID:bid,ids:model.selection) } }
 var readyCount: Int { model.currentBatch?.documents.filter {$0.state == .ready}.count ?? 0 }
 var settingsBinding: Binding<OutputSettings> { Binding(get:{ if individual, let d = model.selectedItem { return model.settings(for:d) }; return model.currentBatch?.settings ?? OutputSettings() },set:{ model.changeSettings($0,individual:individual) }) }
 var sectionSubtitle: String { model.section == "历史任务" ? "查看所有任务的成功、失败和执行详情" : model.section == "进行中" ? "查看所有待执行和正在处理的任务" : model.currentBatch?.name ?? "添加文件后自动创建任务" }
 func historySummary(_ documents:[DocumentItem])->String {
  let states = documents.flatMap { $0.attempts.isEmpty ? [$0.state] : $0.attempts.map(\.state) }
  var summary = "成功 \(states.filter { $0 == .completed }.count) · 失败 \(states.filter { $0 == .failed }.count)"
  let cancelled = states.filter { $0 == .cancelled }.count; let review = states.filter { $0 == .needsReview }.count
  if cancelled > 0 { summary += " · 取消 \(cancelled)" }; if review > 0 { summary += " · 待核实 \(review)" }
  return summary
 }
 func icon(_ s:String)->String { switch s { case "进行中":return "clock"; case "历史任务":return "clock.arrow.circlepath"; default:return "plus.square" } }
 func stateColor(_ s:JobState)->Color { switch s { case .completed:return .teal; case .failed:return .red; case .needsReview:return .orange; case .preparing,.submitting,.processing,.queued:return .blue; default:return .secondary } }
 func statusLabel(_ doc:DocumentItem)->String { if doc.state == .completed { return model.settings(for:doc).target.isPDF ? "已保存" : "系统完成" }; return doc.state.rawValue }
}

struct AttemptHistoryView: View {
 let attempt: OutputAttempt
 var body:some View {
  VStack(alignment:.leading,spacing:6) {
   HStack { Text(attempt.date.formatted(date:.numeric,time:.shortened)); Spacer(); Text(attempt.state == .completed ? (attempt.settings.target.isPDF ? "成功 · 已保存 PDF" : "成功 · 系统报告完成") : attempt.state.rawValue).foregroundStyle(attempt.state == .failed ? Color.red : attempt.state == .completed ? Color.teal : Color.secondary) }.font(.caption.bold())
   Text(attempt.settings.target.label).font(.caption).foregroundStyle(.secondary)
   ForEach(attempt.events) { event in Text("\(event.date.formatted(date:.omitted,time:.shortened))  \(event.message)").font(.caption).textSelection(.enabled) }
   if let path = attempt.outputPath, FileManager.default.fileExists(atPath:path) { HStack { Button("打开 PDF") { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }; Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) } } }
  }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
 }
}

struct OutputSettingsView: View {
 @Binding var settings: OutputSettings
 var printers:[PrinterInfo]; var capabilities:[String:PrinterCapabilities]
 var cap:PrinterCapabilities? { if case .printer(let id) = settings.target { return capabilities[id] }; return nil }
 var body:some View {
  Grid(alignment:.leading,horizontalSpacing:14,verticalSpacing:10) {
   GridRow { Text("输出到").foregroundStyle(.secondary); Picker("输出到",selection:$settings.target) { Text("打印到 PDF").tag(OutputTarget.pdf); ForEach(printers) { Text($0.displayName).tag(OutputTarget.printer($0.id)) }; if case .printer(let id) = settings.target, !printers.contains(where:{$0.id == id}) { Text("\(id)（未连接）").tag(OutputTarget.printer(id)) } }.labelsHidden() }
   GridRow { Text("纸张 / 方向").foregroundStyle(.secondary); HStack { Picker("纸张",selection:$settings.paper) { ForEach(Paper.allCases,id:\.self) { p in Text(p.rawValue).tag(p) } }.labelsHidden(); Picker("方向",selection:$settings.landscape) { Text("纵向").tag(false); Text("横向").tag(true) }.labelsHidden() } }
   GridRow { Text("页面").foregroundStyle(.secondary); TextField("全部，例如 1-3,5",text:$settings.pageRange).textFieldStyle(.roundedBorder) }
   GridRow { Text("缩放 / 旋转").foregroundStyle(.secondary); HStack { Picker("缩放",selection:$settings.fitToPage) { Text("适合纸张").tag(true); Text("实际大小").tag(false) }.labelsHidden(); Picker("旋转",selection:$settings.rotation) { ForEach([0,90,180,270],id:\.self) { Text("\($0)°").tag($0) } }.labelsHidden() } }
   GridRow { Text("颜色").foregroundStyle(.secondary); Picker("颜色",selection:$settings.grayscale) { Text("彩色").tag(false); Text("灰度 / 黑白").tag(true) }.labelsHidden() }
   GridRow { Text("单双面").foregroundStyle(.secondary); Picker("单双面",selection:$settings.duplex) { ForEach(DuplexMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.labelsHidden().disabled(settings.target.isPDF || cap?.supportsDuplex == false) }
   GridRow { Text("份数").foregroundStyle(.secondary); HStack { Stepper("\(settings.effectiveCopies)",value:$settings.copies,in:1...999); Toggle("逐份打印",isOn:$settings.collate) }.disabled(settings.target.isPDF) }
  }
  if settings.target.isPDF { Text("每个文件保存一个 PDF；不重复页面，不覆盖已有文件。").font(.caption).foregroundStyle(.secondary) }
  else if let cap {
   if !cap.papers.isEmpty && !cap.papers.contains(settings.paper.rawValue) { Text("此打印机不支持当前纸张，请修改后再输出。").font(.caption).foregroundStyle(.red) }
   if !cap.supportsColor && !settings.grayscale { Text("未发现彩色能力，请选择黑白；不会静默替换。").font(.caption).foregroundStyle(.red) }
  }
 }
}

final class PDFPreviewContainer:NSView {
 let pdfView = PDFView()
 let thumbnails = PDFThumbnailView()
 private var fitsPage = true
 override init(frame:NSRect) {
  super.init(frame:frame)
  pdfView.autoScales = true; pdfView.displayMode = .singlePage; pdfView.backgroundColor = .underPageBackgroundColor
  thumbnails.pdfView = pdfView; thumbnails.thumbnailSize = CGSize(width:48,height:64)
  let toolbar = NSStackView(); toolbar.spacing = 10; toolbar.orientation = .horizontal
  for (title,action) in [("上一页",#selector(previousPage)),("下一页",#selector(nextPage)),("放大",#selector(zoomIn)),("缩小",#selector(zoomOut))] {
   let button = NSButton(title:title,target:self,action:action); button.bezelStyle = .rounded; button.controlSize = .small; toolbar.addArrangedSubview(button)
  }
  let fit = NSButton(title:"适合窗口",target:self,action:#selector(fitPage)); fit.bezelStyle = .rounded; fit.controlSize = .small; toolbar.addArrangedSubview(fit)
  for view in [thumbnails,pdfView,toolbar] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
  NSLayoutConstraint.activate([
   thumbnails.leadingAnchor.constraint(equalTo:leadingAnchor),thumbnails.topAnchor.constraint(equalTo:topAnchor),thumbnails.bottomAnchor.constraint(equalTo:toolbar.topAnchor,constant:-4),thumbnails.widthAnchor.constraint(equalToConstant:72),
   pdfView.leadingAnchor.constraint(equalTo:thumbnails.trailingAnchor),pdfView.trailingAnchor.constraint(equalTo:trailingAnchor),pdfView.topAnchor.constraint(equalTo:topAnchor),pdfView.bottomAnchor.constraint(equalTo:toolbar.topAnchor,constant:-4),
   toolbar.centerXAnchor.constraint(equalTo:centerXAnchor),toolbar.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-6),toolbar.heightAnchor.constraint(equalToConstant:24)])
 }
 required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
 @objc func previousPage() { pdfView.goToPreviousPage(self); if fitsPage { fitPage() } }
 @objc func nextPage() { pdfView.goToNextPage(self); if fitsPage { fitPage() } }
 @objc func zoomIn() { fitsPage = false; pdfView.zoomIn(self) }
 @objc func zoomOut() { fitsPage = false; pdfView.zoomOut(self) }
 @objc func fitPage() {
  fitsPage = true
  guard let page = pdfView.currentPage ?? pdfView.document?.page(at:0), pdfView.bounds.width > 40, pdfView.bounds.height > 40 else { return }
  let box = page.bounds(for:.mediaBox)
  guard box.width > 0, box.height > 0 else { return }
  let desired = min((pdfView.bounds.width-24)/box.width,(pdfView.bounds.height-24)/box.height)
  if abs(pdfView.scaleFactor-desired) > 0.001 { pdfView.scaleFactor = desired }
 }
 override func layout() { super.layout(); if fitsPage { fitPage() } }
}
struct PDFPreview: NSViewRepresentable {
 let url:URL
 func makeNSView(context:Context)->PDFPreviewContainer { PDFPreviewContainer(frame:.zero) }
 func updateNSView(_ view:PDFPreviewContainer,context:Context) { if view.pdfView.document?.documentURL != url { view.pdfView.document = PDFDocument(url:url); view.fitPage() } }
}

struct PreferencesView:View {
 @EnvironmentObject var model:AppModel
 @Environment(\.dismiss) var dismiss
 var body:some View {
  VStack(alignment:.leading,spacing:16) {
   Text("设置与依赖").font(.title2.bold())
   Form {
    Section("新批次默认设置") { OutputSettingsView(settings:defaultSettingsBinding,printers:model.printers,capabilities:model.capabilities) }
    Section("办公文件转换 · LibreOffice") {
     HStack { Image(systemName:available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(available ? .green : .orange); Text(available ? "已找到 LibreOffice" : "未安装；PDF、图片和文本仍可使用") }
     TextField("转换程序路径",text:$model.snapshot.preferences.libreOfficePath)
     HStack { Button("选择 LibreOffice.app") { let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = [.applicationBundle]; if p.runModal() == .OK, let u = p.url { model.snapshot.preferences.libreOfficePath = u.appendingPathComponent("Contents/MacOS/soffice").path } }; Link("打开官方下载页",destination:URL(string:"https://www.libreoffice.org/download/download-libreoffice/")!) }
     Text("下载适合此 Mac 的版本，将 LibreOffice 拖入“应用程序”，首次手动打开一次，再回到这里。无需命令行。").font(.caption).foregroundStyle(.secondary)
     Stepper("转换超时：\(Int(model.snapshot.preferences.conversionTimeout)) 秒",value:$model.snapshot.preferences.conversionTimeout,in:30...1800,step:30)
    }
    Section("本地数据") {
     Stepper("内部文件保留 \(model.snapshot.preferences.cacheDays) 天",value:$model.snapshot.preferences.cacheDays,in:1...365)
     Stepper("历史记录保留 \(model.snapshot.preferences.historyDays) 天",value:$model.snapshot.preferences.historyDays,in:30...730)
     Text("清理只删除过期内部缓存，不删除你导出的 PDF。").font(.caption).foregroundStyle(.secondary)
     HStack { Button("清理过期数据") { model.cleanup() }; Button("导出日志") { model.exportLog() }; Button("刷新打印机") { model.refreshPrinters() } }
    }
   }.formStyle(.grouped)
   HStack { Text("本地处理 · 不上传文件").font(.caption).foregroundStyle(.secondary); Spacer(); Button("完成") { model.persist(); dismiss() }.keyboardShortcut(.defaultAction) }
 }.padding(20).frame(width:620,height:760)
 }
 private var defaultSettingsBinding: Binding<OutputSettings> {
  Binding(get: { model.snapshot.preferences.defaultSettings }, set: { value in
   model.snapshot.preferences.defaultSettings = value
   model.snapshot.preferences.defaultTargetConfigured = true
  })
 }
 var available:Bool { FileManager.default.isExecutableFile(atPath:model.snapshot.preferences.libreOfficePath) }
}

struct ConversionOptionsView:View {
 @EnvironmentObject var model:AppModel; @Environment(\.dismiss) var dismiss
 @State private var options = ConversionOptions()
 @State private var snippet = ""
 var body:some View {
  VStack(alignment:.leading,spacing:16) {
   Text("转换选项").font(.title2.bold())
   Form {
    Picker("文本编码",selection:$options.textEncoding) { ForEach(["自动","UTF-8","UTF-16","GB18030"],id:\.self) { Text($0) } }
    Picker("CSV 分隔符",selection:$options.csvDelimiter) { Text("逗号").tag(","); Text("分号").tag(";"); Text("制表符").tag("\t"); Text("竖线").tag("|") }
    TextField("Excel 工作表（名称用逗号分隔；留空为全部）",text:$options.selectedSheets)
    Toggle("Excel 所有列适合一页宽",isOn:$options.fitColumns)
   }
   Text("文本 / CSV 源内容预览").font(.headline)
   ScrollView { Text(snippet).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }.frame(height:180).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
   Text("更改会重新转换所选文件。Office 输出仍需检查字体和分页。").font(.caption).foregroundStyle(.secondary)
   HStack { Button("取消") { dismiss() }; Spacer(); Button("应用并重新转换") { model.setConversion(options); dismiss() }.keyboardShortcut(.defaultAction) }
  }.padding(24).frame(width:580).onAppear { options = model.selectedItem?.conversion ?? ConversionOptions(); refresh() }.onChange(of:options.textEncoding) { _,_ in refresh() }
 }
 func refresh() { guard let p = model.selectedItem?.sourcePath, ["txt","csv","md","markdown"].contains(URL(fileURLWithPath:p).pathExtension.lowercased()), let data = try? Data(contentsOf:URL(fileURLWithPath:p)) else { snippet = "当前文件不是可直接预览的文本。"; return }
  let encoding:String.Encoding
  switch options.textEncoding { case "UTF-16":encoding = .utf16; case "GB18030":encoding = String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))); default:encoding = .utf8 }
  snippet = String(data:data,encoding:encoding).map { String($0.prefix(6000)) } ?? "无法按当前编码读取，请切换编码。"
 }
}
