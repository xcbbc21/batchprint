# 批量打印 完整版实现计划
已确认：macOS 14+、中文、本地处理；PDF/Office/图片/网页/文本；所有输出选择器提供打印到 PDF；LibreOffice 外置。
默认：通用二进制、直接分发；不含小册子、装订、部门码；不自动重发不明打印任务。
1. 基础模型、SQLite 持久化、快照、参数与恢复规则（root）。
2. Converter + PDFComposer：全格式转换、纸张/选页/灰度、分页与预览（converter agent）。
3. PrinterBackend：CUPS 能力、提交、状态、取消（printer agent）。
4. 原生三栏 UI、PDF 输出、顺序队列、模板、历史/清理、登录网页（root）。
5. 自动测试、8 PDF 回归、200 文件、通用打包、独立审查和交付文档。
接口协定见 Sources/BatchPrint/Models.swift。各模块不同文件，不互相覆盖。
实际出纸需控制小样本；其他 Mac 和 Intel 运行不具备时如实标未验证。
