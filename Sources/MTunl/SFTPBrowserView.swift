import SwiftUI
import TunnelCore

// MARK: - Local File Model

struct LocalFile: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
}

@MainActor
final class LocalBrowserModel: ObservableObject {
    @Published var currentPath: String = NSHomeDirectory()
    @Published var files: [LocalFile] = []
    @Published var selectedFiles: Set<String> = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Anchor index for shift-click range selection (Finder style).
    var selectionAnchor: Int?

    init() {
        Task { await loadDirectory() }
    }

    func filteredFiles() -> [LocalFile] {
        guard !searchText.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func navigateTo(_ path: String) {
        currentPath = path
        Task { await loadDirectory() }
    }

    func navigateUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigateTo(parent.isEmpty ? "/" : parent)
    }

    func toggleSelection(_ file: LocalFile) {
        if selectedFiles.contains(file.path) {
            selectedFiles.remove(file.path)
        } else {
            selectedFiles.insert(file.path)
        }
    }

    /// Finder-style click handling: plain click selects exclusively,
    /// ⌘-click toggles, ⇧-click selects a range from the anchor.
    /// Folders navigate on plain click; with ⌘/⇧ they participate in selection.
    func handleClick(_ file: LocalFile, index: Int, modifiers: NSEvent.ModifierFlags) {
        if file.isDirectory && modifiers.isEmpty {
            selectionAnchor = nil
            navigateTo(file.path)
            return
        }

        if modifiers.contains(.command) {
            toggleSelection(file)
            selectionAnchor = index
        } else if modifiers.contains(.shift), let anchor = selectionAnchor {
            let lower = min(anchor, index)
            let upper = max(anchor, index)
            let rangeFiles = filteredFiles()[lower...upper]
            selectedFiles = Set(rangeFiles.map { $0.path })
        } else {
            selectedFiles = [file.path]
            selectionAnchor = index
        }
    }

    func selectAllFiles() {
        selectedFiles = Set(files.map { $0.path })
    }

    func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        selectedFiles.removeAll()

        // Scan the directory off the main thread so large folders
        // never block the UI.
        let path = currentPath
        let result = await Task.detached(priority: .userInitiated) { () -> (files: [LocalFile], error: String?) in
            let fm = FileManager.default
            do {
                let items = try fm.contentsOfDirectory(atPath: path)
                var files: [LocalFile] = []
                for name in items {
                    let full = (path as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }

                    let attrs = try? fm.attributesOfItem(atPath: full)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let modified = attrs?[.modificationDate] as? Date

                    files.append(LocalFile(
                        id: full,
                        path: full,
                        name: name,
                        isDirectory: isDir.boolValue,
                        size: isDir.boolValue ? 0 : size,
                        modifiedDate: modified
                    ))
                }
                files.sort { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return (files, nil)
            } catch {
                return ([], error.localizedDescription)
            }
        }.value

        // Ignore stale results if the user navigated away meanwhile.
        guard path == currentPath else { return }
        files = result.files
        errorMessage = result.error
        isLoading = false
    }
}

// MARK: - Remote Browser Model

@MainActor
final class RemoteBrowserModel: ObservableObject {
    @Published var currentPath: String = "/"
    @Published var files: [RemoteFile] = []
    @Published var selectedFiles: Set<String> = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var clipboard: [RemoteFile] = []
    @Published var clipboardOperation: ClipboardOperation?
    @Published var showingNewFolder = false
    @Published var newFolderName = ""
    /// Anchor index for shift-click range selection (Finder style).
    var selectionAnchor: Int?

    let config: TunnelConfig

    enum ClipboardOperation {
        case copy, cut
    }

    init(config: TunnelConfig) {
        self.config = config
    }

    func filteredFiles() -> [RemoteFile] {
        guard !searchText.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func navigateTo(_ path: String) {
        currentPath = path
        Task { await loadDirectory() }
    }

    func navigateUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigateTo(parent.isEmpty ? "/" : parent)
    }

    func toggleSelection(_ file: RemoteFile) {
        if selectedFiles.contains(file.path) {
            selectedFiles.remove(file.path)
        } else {
            selectedFiles.insert(file.path)
        }
    }

    /// Finder-style click handling: plain click selects exclusively,
    /// ⌘-click toggles, ⇧-click selects a range from the anchor.
    /// Folders navigate on plain click; with ⌘/⇧ they participate in selection.
    func handleClick(_ file: RemoteFile, index: Int, modifiers: NSEvent.ModifierFlags) {
        if file.isDirectory && modifiers.isEmpty {
            selectionAnchor = nil
            navigateTo(file.path)
            return
        }

        if modifiers.contains(.command) {
            toggleSelection(file)
            selectionAnchor = index
        } else if modifiers.contains(.shift), let anchor = selectionAnchor {
            let lower = min(anchor, index)
            let upper = max(anchor, index)
            let rangeFiles = filteredFiles()[lower...upper]
            selectedFiles = Set(rangeFiles.map { $0.path })
        } else {
            selectedFiles = [file.path]
            selectionAnchor = index
        }
    }

    func selectAllFiles() {
        selectedFiles = Set(files.map { $0.path })
    }

    func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        selectedFiles.removeAll()

        do {
            files = try await SFTPClient.listDirectory(at: currentPath, config: config)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func copySelected() {
        clipboard = files.filter { selectedFiles.contains($0.path) }
        clipboardOperation = .copy
    }

    func cutSelected() {
        clipboard = files.filter { selectedFiles.contains($0.path) }
        clipboardOperation = .cut
    }

    func paste() async {
        guard !clipboard.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            for file in clipboard {
                let newPath = currentPath + "/" + file.name

                if clipboardOperation == .copy {
                    try await SFTPClient.copyRemote(from: file.path, to: newPath, config: config)
                } else {
                    try await SFTPClient.rename(from: file.path, to: newPath, config: config)
                }
            }

            if clipboardOperation == .cut {
                clipboard.removeAll()
                clipboardOperation = nil
            }

            await loadDirectory()
            selectedFiles.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func deleteSelected() async {
        guard !selectedFiles.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        let targets = files.filter { selectedFiles.contains($0.path) }

        do {
            for file in targets {
                if file.isDirectory {
                    try await SFTPClient.deleteDirectory(remotePath: file.path, config: config)
                } else {
                    try await SFTPClient.deleteFile(remotePath: file.path, config: config)
                }
            }

            await loadDirectory()
            selectedFiles.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func createFolder() async {
        guard !newFolderName.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        let newPath = currentPath + "/" + newFolderName

        do {
            try await SFTPClient.mkdir(remotePath: newPath, config: config)
            newFolderName = ""
            showingNewFolder = false
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func compressSelected() async {
        guard !selectedFiles.isEmpty else { return }

        let archiveName = "archive-\(Int(Date().timeIntervalSince1970)).tar.gz"
        let archivePath = currentPath + "/" + archiveName

        isLoading = true
        errorMessage = nil

        let targets = files.filter { selectedFiles.contains($0.path) }

        do {
            try await SFTPClient.compress(
                remotePaths: targets.map { $0.path },
                archivePath: archivePath,
                config: config
            )
            await loadDirectory()
            selectedFiles.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func decompressSelected() async {
        guard selectedFiles.count == 1 else { return }

        guard let file = files.first(where: { selectedFiles.contains($0.path) }) else {
            return
        }
        
        // Check if it's a supported archive format
        guard SFTPClient.isSupportedArchive(file.name) else {
            errorMessage = "不支持的压缩格式。支持的格式：.tar.gz, .tgz, .tar.bz2, .tbz2, .tbz, .tar.xz, .txz, .tar, .zip, .rar, .7z, .gz, .bz2, .xz"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await SFTPClient.decompress(archivePath: file.path, destinationPath: currentPath, config: config)
            await loadDirectory()
            selectedFiles.removeAll()
        } catch {
            let errorDesc = error.localizedDescription
            // Provide more helpful error messages for common cases
            if errorDesc.contains("command not found") {
                if file.name.hasSuffix(".zip") {
                    errorMessage = "解压失败：远程服务器缺少 unzip 命令。\n错误：\(errorDesc)"
                } else if file.name.hasSuffix(".rar") {
                    errorMessage = "解压失败：远程服务器缺少 unrar 命令（或使用 unar/7z）。\n错误：\(errorDesc)"
                } else if file.name.hasSuffix(".7z") {
                    errorMessage = "解压失败：远程服务器缺少 7z 命令（需要安装 p7zip）。\n错误：\(errorDesc)"
                } else {
                    errorMessage = "解压失败：\(errorDesc)"
                }
            } else {
                errorMessage = errorDesc
            }
        }

        isLoading = false
    }
}

// MARK: - Main View

struct SFTPBrowserView: View {
    @StateObject private var localModel = LocalBrowserModel()
    @StateObject private var remoteModel: RemoteBrowserModel
    @StateObject private var transferQueue = TransferQueue()
    @State private var showingCredentialSheet = false

    init(config: TunnelConfig) {
        _remoteModel = StateObject(wrappedValue: RemoteBrowserModel(config: config))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LocalPaneView(model: localModel)
                    .frame(minWidth: 320, maxWidth: .infinity, minHeight: 420)

                VStack(spacing: 12) {
                    transferButton(direction: .upload)
                    transferButton(direction: .download)
                }
                .frame(width: 110)
                .padding(.horizontal, 8)

                RemotePaneView(model: remoteModel, onOpenCredentials: {
                    showingCredentialSheet = true
                })
                .frame(minWidth: 320, maxWidth: .infinity, minHeight: 420)
            }

            if !transferQueue.items.isEmpty {
                Divider()
                TransferQueueBar(queue: transferQueue)
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .task {
            await remoteModel.loadDirectory()
        }
        // Refresh both panes once the queue fully drains.
        .onChange(of: transferQueue.activeCount) { count in
            if count == 0 {
                Task { await localModel.loadDirectory() }
                Task { await remoteModel.loadDirectory() }
            }
        }
        .alert("新建文件夹", isPresented: $remoteModel.showingNewFolder) {
            TextField("文件夹名称", text: $remoteModel.newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task { await remoteModel.createFolder() }
            }
        }
        .sheet(isPresented: $showingCredentialSheet) {
            CredentialSheetView(config: remoteModel.config) {
                Task { await remoteModel.loadDirectory() }
            }
        }
    }

    private func transferButton(direction: TransferDirection) -> some View {
        let canTransfer: Bool
        let label: String
        let icon: String

        switch direction {
        case .upload:
            canTransfer = !localModel.selectedFiles.isEmpty
            label = "上传"
            icon = "arrow.right.circle.fill"
        case .download:
            canTransfer = !remoteModel.selectedFiles.isEmpty
            label = "下载"
            icon = "arrow.left.circle.fill"
        }

        return Button {
            let config = remoteModel.config
            switch direction {
            case .upload:
                let selected = localModel.files.filter { localModel.selectedFiles.contains($0.path) }
                transferQueue.enqueueUploads(selected, to: remoteModel.currentPath, config: config)
                localModel.selectedFiles.removeAll()
            case .download:
                let selected = remoteModel.files.filter { remoteModel.selectedFiles.contains($0.path) }
                transferQueue.enqueueDownloads(selected, to: localModel.currentPath, config: config)
                remoteModel.selectedFiles.removeAll()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
        }
        .disabled(!canTransfer)
        .buttonStyle(.borderedProminent)
        .help(direction == .upload
              ? "把左侧选中的文件加入上传队列，传到右侧当前远程目录"
              : "把右侧选中的文件加入下载队列，存到左侧当前本地目录")
    }
}

private enum TransferDirection {
    case upload, download
}

// MARK: - Transfer Queue Bar

struct TransferQueueBar: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("传输队列")
                    .font(.headline)
                Text("\(queue.activeCount) 个进行中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空已完成") { queue.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(queue.activeCount == queue.items.count)
                Button("全部取消") { queue.cancelAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(queue.activeCount == 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            List(queue.items) { item in
                TransferItemRow(item: item) { queue.cancel(item) }
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            }
            .listStyle(.plain)
            .frame(maxHeight: 160)
        }
    }
}

struct TransferItemRow: View {
    @ObservedObject var item: TransferQueue.TransferItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch item.state {
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(item.error ?? "")
            case .cancelled:
                Image(systemName: "slash.circle")
                    .foregroundStyle(.secondary)
            }

            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(item.direction == .upload ? "上传" : "下载")

            Text(item.name)
                .lineLimit(1)

            Spacer()

            Text(stateText)
                .font(.caption)
                .foregroundStyle(item.state == .failed ? .red : .secondary)

            if item.state == .queued || item.state == .running {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消传输")
            }
        }
        .padding(.vertical, 2)
    }

    private var stateText: String {
        switch item.state {
        case .queued: return "排队中"
        case .running: return "传输中…"
        case .completed: return "已完成"
        case .failed: return item.error ?? "失败"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - Breadcrumb Bar

/// Windows-explorer style path bar: the path is split on "/" and each
/// segment is a button that jumps straight to that folder.
struct BreadcrumbBar: View {
    let path: String
    let onNavigate: (String) -> Void

    private struct Segment: Identifiable {
        let id: Int
        let name: String
        let target: String
    }

    private var segments: [Segment] {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        var result: [Segment] = []
        var cumulative = ""
        for (index, part) in parts.enumerated() {
            if index == 0 {
                // Handle paths like "~" or absolute "/"-rooted ones.
                cumulative = part == "~" ? part : "/" + part
            } else {
                cumulative = cumulative.hasSuffix("/") ? cumulative + part : cumulative + "/" + part
            }
            result.append(Segment(id: index, name: part, target: cumulative))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button(action: { onNavigate("/") }) {
                    Image(systemName: "externaldrive")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("根目录")

                ForEach(segments) { segment in
                    Text("/")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(action: { onNavigate(segment.target) }) {
                        Text(segment.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(segment.target)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Local Pane

struct LocalPaneView: View {
    @ObservedObject var model: LocalBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            searchBar
            Divider()

            if model.isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredFiles().isEmpty {
                emptyView
            } else {
                fileList
            }

            if let error = model.errorMessage {
                errorBar(error) { model.errorMessage = nil }
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Text("本机")
                .font(.headline)

            Spacer()

            Button(action: { model.navigateUp() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(model.currentPath == "/" || model.currentPath == NSHomeDirectory())
            .help("返回上级")

            BreadcrumbBar(path: model.currentPath) { model.navigateTo($0) }
                .frame(maxWidth: .infinity)

            Button(action: { Task { await model.loadDirectory() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新")

            Menu {
                Button("全选文件") { model.selectAllFiles() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("取消全选") { model.selectedFiles.removeAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            } label: {
                Image(systemName: "checklist")
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("选择")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("筛选文件…", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(model.searchText.isEmpty ? "目录为空" : "没有匹配的文件")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(Array(model.filteredFiles().enumerated()), id: \.element.id) { index, file in
            LocalFileRow(
                file: file,
                isSelected: model.selectedFiles.contains(file.path)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Finder 风格：单击单选，⌘单击切换，⇧单击范围选择；文件夹单击进入
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                model.handleClick(file, index: index, modifiers: modifiers)
            }
            .listRowBackground(
                model.selectedFiles.contains(file.path)
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
            )
        }
        .listStyle(.plain)
    }

    private func errorBar(_ message: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("清除", action: clear)
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(6)
        .background(Color.red.opacity(0.1))
    }
}

struct LocalFileRow: View {
    let file: LocalFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            Text(file.name)
                .lineLimit(1)

            Spacer()

            if !file.isDirectory {
                Text(formatSize(file.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Remote Pane

struct RemotePaneView: View {
    @ObservedObject var model: RemoteBrowserModel
    var onOpenCredentials: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            searchBar
            Divider()

            if model.isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredFiles().isEmpty {
                emptyView
            } else {
                fileList
            }

            if let error = model.errorMessage {
                errorBar(error) { model.errorMessage = nil }
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Text("远程")
                .font(.headline)

            Spacer()

            Button(action: { model.navigateUp() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(model.currentPath == "/")
            .help("返回上级")

            BreadcrumbBar(path: model.currentPath) { model.navigateTo($0) }
                .frame(maxWidth: .infinity)

            Button(action: { Task { await model.loadDirectory() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新")

            Menu {
                Button("连接密码（钥匙串）…") {
                    onOpenCredentials()
                }

                Divider()

                Button("全选文件") { model.selectAllFiles() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("取消全选") { model.selectedFiles.removeAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("新建文件夹") { model.showingNewFolder = true }

                Divider()

                Button("压缩选中") {
                    Task { await model.compressSelected() }
                }
                .disabled(model.selectedFiles.isEmpty)

                Button("解压选中") {
                    Task { await model.decompressSelected() }
                }
                .disabled(model.selectedFiles.count != 1)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多操作")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("筛选文件…", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button(action: { model.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(model.searchText.isEmpty ? "目录为空" : "没有匹配的文件")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(Array(model.filteredFiles().enumerated()), id: \.element.id) { index, file in
            RemoteFileRow(
                file: file,
                isSelected: model.selectedFiles.contains(file.path)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Finder 风格：单击单选，⌘单击切换，⇧单击范围选择；文件夹单击进入
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                model.handleClick(file, index: index, modifiers: modifiers)
            }
            .contextMenu { contextMenu(for: file) }
            .listRowBackground(
                model.selectedFiles.contains(file.path)
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
            )
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func contextMenu(for file: RemoteFile) -> some View {
        if file.isDirectory {
            Button("打开") { model.navigateTo(file.path) }
        }

        if !file.isDirectory {
            Button("选中") { model.selectedFiles = [file.path] }
        }

        Divider()

        Button("复制") {
            model.selectedFiles = [file.path]
            model.copySelected()
        }
        Button("剪切") {
            model.selectedFiles = [file.path]
            model.cutSelected()
        }
        if !model.clipboard.isEmpty {
            Button("粘贴到此处") {
                Task { await model.paste() }
            }
        }

        Divider()

        Button("删除", role: .destructive) {
            model.selectedFiles = [file.path]
            Task { await model.deleteSelected() }
        }
    }

    private func errorBar(_ message: String, clear: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("清除", action: clear)
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(6)
        .background(Color.red.opacity(0.1))
    }
}

struct RemoteFileRow: View {
    let file: RemoteFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(file.permissions)
                    Text("\(file.owner):\(file.group)")
                    if !file.isDirectory {
                        Text(formatSize(file.size))
                    }
                    Text(file.modifiedTime)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Credential Sheet

struct CredentialSheetView: View {
    let config: TunnelConfig
    var onSaved: () -> Void

    @State private var password = ""
    @State private var statusText = ""
    @State private var hasStored = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接密码")
                .font(.headline)

            Text("服务器 \(MTunlKeychain.account(for: config)) 使用密码认证时，可把密码保存到 macOS 钥匙串，SFTP 将自动完成认证。密码不进入命令行参数，也不会写入文件。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("保存到钥匙串") {
                    if MTunlKeychain.savePassword(password, for: config) {
                        statusText = "已保存，正在重新连接…"
                        hasStored = true
                        password = ""
                        onSaved()
                    } else {
                        statusText = "保存失败"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)

                Button("从钥匙串删除", role: .destructive) {
                    hasStored = !MTunlKeychain.deletePassword(for: config)
                    statusText = hasStored ? "删除失败" : "已删除"
                }
                .disabled(!hasStored)

                Spacer()

                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            hasStored = MTunlKeychain.hasPassword(for: config)
            if hasStored {
                statusText = "钥匙串中已保存该服务器的密码"
            }
        }
    }
}

#Preview {
    SFTPBrowserView(config: TunnelConfig(
        name: "测试服务器",
        host: "example.com",
        user: "user"
    ))
}
