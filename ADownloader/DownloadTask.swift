//
//  DownloadTask.swift
//  ADownloader
//
//  Created by Codex on 4/7/26.
//

import Foundation
import SwiftData

enum DownloadStatus: String, CaseIterable, Codable {
  case active
  case waiting
  case paused
  case complete
  case error
  case removed
}

@Model
final class DownloadTask {
  @Attribute(.unique) var id: UUID
  var gid: String?
  var sourceURL: String
  var displayName: String
  var statusRaw: String
  var totalBytes: Int64
  var completedBytes: Int64
  var downloadSpeed: Int64
  var connections: Int
  var fileName: String
  var directoryPath: String
  var directoryBookmark: Data?
  var createdAt: Date
  var updatedAt: Date
  var completedAt: Date?
  var errorMessage: String?

  init(
    id: UUID = UUID(),
    gid: String? = nil,
    sourceURL: String,
    displayName: String,
    status: DownloadStatus,
    totalBytes: Int64 = 0,
    completedBytes: Int64 = 0,
    downloadSpeed: Int64 = 0,
    connections: Int = 0,
    fileName: String,
    directoryPath: String,
    directoryBookmark: Data? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    completedAt: Date? = nil,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.gid = gid
    self.sourceURL = sourceURL
    self.displayName = displayName
    self.statusRaw = status.rawValue
    self.totalBytes = totalBytes
    self.completedBytes = completedBytes
    self.downloadSpeed = downloadSpeed
    self.connections = connections
    self.fileName = fileName
    self.directoryPath = directoryPath
    self.directoryBookmark = directoryBookmark
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
    self.errorMessage = errorMessage
  }
}

extension DownloadTask {
  var status: DownloadStatus {
    get { DownloadStatus(rawValue: statusRaw) ?? .error }
    set { statusRaw = newValue.rawValue }
  }

  var progress: Double {
    guard totalBytes > 0 else { return 0 }
    return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
  }

  var filePath: String {
    URL(fileURLWithPath: directoryPath)
      .appending(path: fileName)
      .path(percentEncoded: false)
  }
}

extension DownloadTask {
  func apply(snapshot: Aria2TaskSnapshot) {
    gid = snapshot.gid
    status = snapshot.status
    totalBytes = snapshot.totalBytes
    completedBytes = snapshot.completedBytes
    downloadSpeed = snapshot.downloadSpeed
    connections = snapshot.connections
    if let fileName = snapshot.fileName, !fileName.isEmpty {
      self.fileName = fileName
    }
    if let displayName = snapshot.displayName, !displayName.isEmpty {
      self.displayName = displayName
    }
    errorMessage = snapshot.errorMessage
    updatedAt = .now

    if snapshot.status == .complete, completedAt == nil {
      completedAt = .now
    }
  }
}
