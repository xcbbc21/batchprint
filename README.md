# 批量打印

面向个人和小团队的 macOS 原生多格式批量打印工具。它把常见文件先整理为 PDF，再交给实体打印机或“打印到 PDF”输出，方便预览、排序、重试和追踪。

> 当前版本只支持 macOS。Windows、Linux 和移动端不在本仓库范围内。

## 当前版本

- 版本：1.0.2
- 系统：macOS 14 或更新版本
- 架构：Apple Silicon 与 Intel 通用
- 界面：中文
- 处理方式：文件在本机处理，不上传云端
- 许可证：MIT（见 LICENSE）

## 功能

- 批量导入文件、文件夹和网页地址。
- 支持 PDF、Word、Excel、PPT、ODF、RTF、CSV、JPEG、PNG、HEIC、TIFF、HTML、TXT 和 Markdown。
- PDF 预览、页码选择、页面旋转、纸张和方向设置。
- 输出目标固定包含“打印到 PDF”，也可选择 macOS 已配置的实体打印机。
- 实体打印支持单双面、长短边翻转、彩色/灰度、份数和逐份打印。
- PDF 输出按源文件逐个保存，不覆盖源文件或已有文件。
- 任务参数、逐文件覆盖、模板、跨任务历史、失败重试和日志导出。
- 历史任务按任务分组显示成功、失败、取消和待核实记录，并保留执行时间、原因及输出文件。
- 删除任务、删除批次和撤销最近一次删除。
- 转换失败、密码 PDF、离线打印机、提交响应丢失等情况显示明确状态。
- 关闭应用后可核对并恢复未完成任务，避免不明确提交自动重打。

## 使用

1. 在 macOS 中添加打印机（如果需要实体打印）。
2. 打开应用，点击“新建任务”并添加文件，或直接拖入文件。
3. 等待文件状态变为“待执行”，点击文件查看右侧 PDF 预览。
4. 在“输出到”中选择“打印到 PDF”或实体打印机。
5. 设置纸张、页码、方向、缩放、颜色等参数。
6. 选择“保存 PDF”或“开始输出”。
7. 已取消或失败的任务，可选中后右键“再次输出 / 重试”。
8. 删除任务不会删除原始文件和已经导出的 PDF。

Office 文件需要 LibreOffice：

1. 从 LibreOffice 官方下载页下载 macOS 版本。
2. 将 LibreOffice 拖入“应用程序”，首次手动打开一次。
3. 回到应用的“设置与依赖”，确认已找到 LibreOffice。

没有 LibreOffice 时，PDF、图片、网页和文本仍可使用，办公文件转换不可用。

## 构建

需要 macOS 14+、Swift 6 工具链（Xcode 或 Command Line Tools 均可）。

~~~sh
./scripts/build.sh "$PWD/dist"
~~~

脚本会分别构建 arm64 和 x86_64，再合并为通用 .app 并进行本地签名。构建不下载 Swift 包依赖。LibreOffice 不会被打进应用。

运行本地功能自测：

~~~sh
./scripts/test.sh
~~~

具备完整 XCTest 环境时，可运行：

~~~sh
swift test
~~~

完整构建、验收和依赖说明见：

- 构建说明：docs/构建说明.md
- 使用手册：docs/使用手册.md
- 验收报告：docs/验收报告.md
- 第三方组件：docs/第三方组件.md
- 更新记录：CHANGELOG.md

## 技术路线

~~~text
SwiftUI / AppKit
    ↓
文件识别与本地快照
    ↓
格式转换器（LibreOffice、系统框架、WebKit）
    ↓
PDF 中间层（PDFKit / CoreGraphics）
    ↓
输出排版与预览
    ↓
PDF 文件或 CUPS 打印队列
~~~

主应用使用 macOS 系统框架、SQLite 和 CUPS。LibreOffice 由使用者单独安装，相关许可证以其官方发行包为准。项目没有把 LibreOffice、字体或打印机驱动打包进应用。

## 贡献

欢迎提交 macOS 相关的错误报告、兼容性记录和改进建议。提交问题时请注明：

- macOS 版本和 Mac 芯片类型；
- 输入文件格式；
- LibreOffice 版本（如涉及 Office 文件）；
- 打印机型号和 CUPS 状态（如涉及实体打印）；
- 应用显示的任务状态和错误信息。

当前不接受 Windows、Linux 或移动端适配作为本版本范围内的实现目标。

## 许可证

本项目代码使用 MIT License。第三方组件的许可证请查看 docs/第三方组件.md。
