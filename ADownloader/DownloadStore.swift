//
//  DownloadStore.swift
//  ADownloader
//
//  Created by Codex on 4/7/26.
//

import AppKit
import Foundation
import Observation
import SwiftData

enum DownloadSidebar: String, CaseIterable, Identifiable {
  case active
  case completed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .active:
      "正在下载"
    case .completed:
      "已完成"
    }
  }

  var systemImage: String {
    switch self {
    case .active:
      "arrow.down.circle"
    case .completed:
      "checkmark.circle"
    }
  }
}

@MainActor
@Observable
final class DownloadStore {
  var selectedSidebar: DownloadSidebar = .active
  var activeTasks: [DownloadTask] = []
  var completedTasks: [DownloadTask] = []
  var alertMessage: String?

  @ObservationIgnored private let service = Aria2Service()
  @ObservationIgnored private var modelContext: ModelContext?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private var activeDirectoryAccess: [UUID: URL] = [:]
  @ObservationIgnored private var didConfigure = false

  deinit {
    syncTask?.cancel()
    activeDirectoryAccess.values.forEach { $0.stopAccessingSecurityScopedResource() }
  }

  func configure(modelContext: ModelContext) {
    guard !didConfigure else { return }

    self.modelContext = modelContext
    didConfigure = true
    reloadTasks()

    guard !Self.isRunningPreview else { return }

    syncTask = Task { [weak self] in
      await self?.bootstrap()
    }
  }

  func addDownload(sourceURLString: String, directoryURL: URL) async {
    guard let modelContext else { return }

    let trimmedURL = sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sourceURL = URL(string: trimmedURL), let scheme = sourceURL.scheme, ["http", "https", "magnet"].contains(scheme.lowercased()) else {
      alertMessage = "请输入有效的下载链接。"
      return
    }

    do {
      let bookmark = try directoryURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      let fileName = suggestedFileName(from: sourceURL)
      let task = DownloadTask(
        sourceURL: trimmedURL,
        displayName: fileName,
        status: .waiting,
        fileName: fileName,
        directoryPath: directoryURL.path(percentEncoded: false),
        directoryBookmark: bookmark
      )

      modelContext.insert(task)
      startDirectoryAccess(for: task)
      try saveContext()
      reloadTasks()

      let gid = try await service.addDownload(sourceURL: sourceURL, directoryURL: directoryURL)
      task.gid = gid
      task.updatedAt = .now
      try saveContext()
      await syncNow()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func pause(_ task: DownloadTask) async {
    guard let gid = task.gid else { return }

    do {
      try await service.pause(gid: gid)
      task.status = .paused
      task.updatedAt = .now
      try saveContext()
      reloadTasks()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func resume(_ task: DownloadTask) async {
    guard let gid = task.gid else { return }

    do {
      try await service.unpause(gid: gid)
      task.status = .active
      task.updatedAt = .now
      try saveContext()
      reloadTasks()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func cancel(_ task: DownloadTask) async {
    guard let modelContext else { return }

    do {
      if let gid = task.gid {
        try await service.remove(gid: gid)
      }

      stopDirectoryAccess(for: task)
      modelContext.delete(task)
      try saveContext()
      reloadTasks()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func retry(_ task: DownloadTask) async {
    guard let sourceURL = URL(string: task.sourceURL) else {
      alertMessage = "原始下载链接无效。"
      return
    }

    guard let directoryURL = resolveDirectoryURL(for: task) else {
      alertMessage = "无法恢复下载目录权限。"
      return
    }

    do {
      if let gid = task.gid {
        try? await service.remove(gid: gid)
      }

      startDirectoryAccess(for: task)
      task.gid = nil
      task.status = .waiting
      task.totalBytes = 0
      task.completedBytes = 0
      task.downloadSpeed = 0
      task.connections = 0
      task.completedAt = nil
      task.errorMessage = nil
      task.updatedAt = .now
      try saveContext()
      reloadTasks()

      let gid = try await service.addDownload(sourceURL: sourceURL, directoryURL: directoryURL)
      task.gid = gid
      task.updatedAt = .now
      try saveContext()
      await syncNow()
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  func openFile(for task: DownloadTask) {
    do {
      let targetURL = try resolvedOpenTargetURL(for: task)
      guard FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)) else {
        throw CocoaError(.fileNoSuchFile)
      }
      NSWorkspace.shared.open(targetURL)
    } catch {
      alertMessage = "找不到文件或目录：\(task.displayName)"
    }
  }

  func revealFile(for task: DownloadTask) {
    do {
      let targetURL = try resolvedOpenTargetURL(for: task)
      guard FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)) else {
        throw CocoaError(.fileNoSuchFile)
      }
      NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    } catch {
      alertMessage = "Finder 中无法定位该文件。"
    }
  }

  func clearAlert() {
    alertMessage = nil
  }

  private func bootstrap() async {
    for task in activeTasks {
      startDirectoryAccess(for: task)
    }

    while !Task.isCancelled {
      await syncNow()
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }

  private func syncNow() async {
    let defaultDirectory = activeTasks.first.flatMap(resolveDirectoryURL(for:)) ?? Self.fallbackDownloadDirectory

    do {
      try await service.startIfNeeded(defaultDirectory: defaultDirectory)
      let snapshots = try await service.fetchAllStatuses()
      applySnapshots(snapshots)
    } catch {
      alertMessage = error.localizedDescription
    }
  }

  private func applySnapshots(_ snapshots: [Aria2TaskSnapshot]) {
    guard let modelContext else { return }

    let snapshotsByGID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.gid, $0) })
    let allTasks = fetchAllTasks()

    for task in allTasks {
      if let gid = task.gid, let snapshot = snapshotsByGID[gid] {
        task.apply(snapshot: snapshot)

        switch snapshot.status {
        case .complete:
          stopDirectoryAccess(for: task)
        case .removed:
          stopDirectoryAccess(for: task)
          modelContext.delete(task)
        case .active, .waiting, .paused:
          startDirectoryAccess(for: task)
        case .error:
          stopDirectoryAccess(for: task)
        }
      } else if task.status != .complete, task.status != .removed {
        if fileExists(for: task) {
          continue
        }

        task.status = .error
        task.errorMessage = task.errorMessage ?? "aria2 中找不到该任务。"
        task.updatedAt = .now
        stopDirectoryAccess(for: task)
      }
    }

    do {
      try saveContext()
    } catch {
      alertMessage = error.localizedDescription
    }

    reloadTasks()
  }

  private func reloadTasks() {
    let allTasks = fetchAllTasks()

    activeTasks = allTasks
      .filter { $0.status != .complete && $0.status != .removed }
      .sorted { $0.updatedAt > $1.updatedAt }
    completedTasks = allTasks
      .filter { $0.status == .complete }
      .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
  }

  private func fetchAllTasks() -> [DownloadTask] {
    guard let modelContext else { return [] }

    let descriptor = FetchDescriptor<DownloadTask>(
      sortBy: [
        SortDescriptor(\DownloadTask.updatedAt, order: .reverse),
        SortDescriptor(\DownloadTask.createdAt, order: .reverse),
      ]
    )

    return (try? modelContext.fetch(descriptor)) ?? []
  }

  private func saveContext() throws {
    guard let modelContext else { return }
    if modelContext.hasChanges {
      try modelContext.save()
    }
  }

  private func suggestedFileName(from sourceURL: URL) -> String {
    if sourceURL.scheme?.lowercased() == "magnet",
       let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
       let dn = components.queryItems?.first(where: { $0.name == "dn" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
       !dn.isEmpty {
      return dn
    }

    let lastPathComponent = sourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return lastPathComponent.isEmpty ? sourceURL.host() ?? "download" : lastPathComponent
  }

  private func resolveDirectoryURL(for task: DownloadTask) -> URL? {
    if let activeURL = activeDirectoryAccess[task.id] {
      return activeURL
    }

    guard let bookmark = task.directoryBookmark else {
      return URL(filePath: task.directoryPath, directoryHint: .isDirectory)
    }

    var isStale = false
    let url = try? URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    return url ?? URL(filePath: task.directoryPath, directoryHint: .isDirectory)
  }

  private func startDirectoryAccess(for task: DownloadTask) {
    guard activeDirectoryAccess[task.id] == nil, let directoryURL = resolveDirectoryURL(for: task) else { return }
    guard directoryURL.startAccessingSecurityScopedResource() else { return }
    activeDirectoryAccess[task.id] = directoryURL
  }

  private func stopDirectoryAccess(for task: DownloadTask) {
    guard let directoryURL = activeDirectoryAccess.removeValue(forKey: task.id) else { return }
    directoryURL.stopAccessingSecurityScopedResource()
  }

  private func resolvedFileURL(for task: DownloadTask) throws -> URL {
    let directoryURL = resolveDirectoryURL(for: task) ?? URL(filePath: task.directoryPath, directoryHint: .isDirectory)
    return directoryURL.appending(path: task.fileName)
  }

  private func resolvedOpenTargetURL(for task: DownloadTask) throws -> URL {
    let directoryURL = resolveDirectoryURL(for: task) ?? URL(filePath: task.directoryPath, directoryHint: .isDirectory)
    let candidates = [
      directoryURL.appending(path: task.fileName),
      directoryURL.appending(path: task.displayName),
      directoryURL,
    ]

    if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) {
      return existing
    }

    return candidates[0]
  }

  private func fileExists(for task: DownloadTask) -> Bool {
    guard let fileURL = try? resolvedOpenTargetURL(for: task) else { return false }
    return FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
  }
}

private extension DownloadStore {
  static var isRunningPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
  }

  static var fallbackDownloadDirectory: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
  }
}
