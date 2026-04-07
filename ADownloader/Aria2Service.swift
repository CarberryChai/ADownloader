//
//  Aria2Service.swift
//  ADownloader
//
//  Created by Codex on 4/7/26.
//

import Foundation
import Network

struct Aria2TaskSnapshot: Sendable {
  let gid: String
  let status: DownloadStatus
  let totalBytes: Int64
  let completedBytes: Int64
  let downloadSpeed: Int64
  let connections: Int
  let fileName: String?
  let displayName: String?
  let errorMessage: String?
}

enum Aria2ServiceError: LocalizedError {
  case executableMissing
  case invalidResponse
  case rpcError(String)
  case startupTimeout

  var errorDescription: String? {
    switch self {
    case .executableMissing:
      "找不到 aria2c 可执行文件。"
    case .invalidResponse:
      "aria2 返回了无效响应。"
    case .rpcError(let message):
      message
    case .startupTimeout:
      "aria2 启动超时。"
    }
  }
}

actor Aria2Service {
  private var process: Process?
  private var rpcPort: Int?
  private var rpcSecret: String?
  private let session = URLSession(configuration: .ephemeral)

  func startIfNeeded(defaultDirectory: URL) async throws {
    if let process, process.isRunning, rpcPort != nil, rpcSecret != nil {
      return
    }

    let executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/aria2c")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path(percentEncoded: false)) else {
      throw Aria2ServiceError.executableMissing
    }

    let appSupportDirectory = try Self.makeAppSupportDirectory()
    let sessionFileURL = appSupportDirectory.appending(path: "aria2.session")
    if !FileManager.default.fileExists(atPath: sessionFileURL.path(percentEncoded: false)) {
      FileManager.default.createFile(atPath: sessionFileURL.path(percentEncoded: false), contents: nil)
    }

    let port = try await Self.allocatePort()
    let secret = UUID().uuidString
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "--enable-rpc=true",
      "--rpc-listen-all=false",
      "--rpc-listen-port=\(port)",
      "--rpc-secret=\(secret)",
      "--continue=true",
      "--save-session=\(sessionFileURL.path(percentEncoded: false))",
      "--input-file=\(sessionFileURL.path(percentEncoded: false))",
      "--save-session-interval=1",
      "--dir=\(defaultDirectory.path(percentEncoded: false))",
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    process.terminationHandler = { [weak self] _ in
      Task {
        await self?.resetRuntimeState()
      }
    }

    try process.run()
    self.process = process
    self.rpcPort = port
    self.rpcSecret = secret

    try await waitUntilReady()
  }

  func addDownload(sourceURL: URL, directoryURL: URL) async throws -> String {
    try await startIfNeeded(defaultDirectory: directoryURL)
    let result = try await call(
      "aria2.addUri",
      params: [
        [sourceURL.absoluteString],
        ["dir": directoryURL.path(percentEncoded: false)],
      ]
    )

    guard let gid = result as? String else {
      throw Aria2ServiceError.invalidResponse
    }

    return gid
  }

  func pause(gid: String) async throws {
    _ = try await call("aria2.pause", params: [gid])
  }

  func unpause(gid: String) async throws {
    _ = try await call("aria2.unpause", params: [gid])
  }

  func remove(gid: String) async throws {
    do {
      _ = try await call("aria2.remove", params: [gid])
    } catch {
      _ = try await call("aria2.forceRemove", params: [gid])
    }
  }

  func fetchAllStatuses() async throws -> [Aria2TaskSnapshot] {
    try await startIfNeeded(defaultDirectory: Self.fallbackDownloadDirectory())
    let active = try await fetchSnapshots(method: "aria2.tellActive")
    let waiting = try await fetchSnapshots(method: "aria2.tellWaiting", params: [0, 1_000])
    let stopped = try await fetchSnapshots(method: "aria2.tellStopped", params: [0, 1_000])
    return active + waiting + stopped
  }

  private func fetchSnapshots(method: String, params: [Any] = []) async throws -> [Aria2TaskSnapshot] {
    let result = try await call(method, params: params)
    guard let items = result as? [[String: Any]] else {
      throw Aria2ServiceError.invalidResponse
    }

    return items.compactMap(Self.makeSnapshot)
  }

  private func call(_ method: String, params: [Any] = []) async throws -> Any {
    guard let rpcPort, let rpcSecret else {
      throw Aria2ServiceError.rpcError("aria2 RPC 尚未初始化。")
    }

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(rpcPort)/jsonrpc")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": UUID().uuidString,
      "method": method,
      "params": ["token:\(rpcSecret)"] + params,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else {
      throw Aria2ServiceError.invalidResponse
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Aria2ServiceError.invalidResponse
    }

    if let error = json["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "aria2 RPC 调用失败。"
      throw Aria2ServiceError.rpcError(message)
    }

    return json["result"] as Any
  }

  private func waitUntilReady() async throws {
    for _ in 0 ..< 20 {
      do {
        _ = try await call("aria2.getVersion")
        return
      } catch {
        try await Task.sleep(for: .milliseconds(250))
      }
    }

    throw Aria2ServiceError.startupTimeout
  }

  private func resetRuntimeState() {
    process = nil
    rpcPort = nil
    rpcSecret = nil
  }
}

private extension Aria2Service {
  static func fallbackDownloadDirectory() -> URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
  }

  static func makeAppSupportDirectory() throws -> URL {
    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
    let directoryURL = baseURL.appending(path: "ADownloader", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
  }

  static func allocatePort() async throws -> Int {
    try await withCheckedThrowingContinuation { continuation in
      do {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready:
            let port = Int(listener.port?.rawValue ?? 0)
            listener.cancel()
            continuation.resume(returning: port)
          case .failed(let error):
            listener.cancel()
            continuation.resume(throwing: error)
          default:
            break
          }
        }
        listener.start(queue: DispatchQueue(label: "aria2.port"))
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  static func makeSnapshot(item: [String: Any]) -> Aria2TaskSnapshot? {
    guard
      let gid = item["gid"] as? String,
      let statusRaw = item["status"] as? String,
      let status = DownloadStatus(rawValue: statusRaw)
    else {
      return nil
    }

    let firstFile = (item["files"] as? [[String: Any]])?.first
    let path = (firstFile?["path"] as? String) ?? ""
    let pathName = path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
    let firstURI = ((firstFile?["uris"] as? [[String: Any]])?.first)?["uri"] as? String
    let magnetDisplayName: String?
    if let firstURI, let components = URLComponents(string: firstURI) {
      magnetDisplayName = components.queryItems?.first(where: { $0.name == "dn" })?.value
    } else {
      magnetDisplayName = nil
    }
    let bittorrentDisplayName = (((item["bittorrent"] as? [String: Any])?["info"] as? [String: Any])?["name"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let completedBytes = Int64((item["completedLength"] as? String) ?? "0") ?? 0
    let totalBytes = Int64((item["totalLength"] as? String) ?? "0") ?? 0
    let downloadSpeed = Int64((item["downloadSpeed"] as? String) ?? "0") ?? 0
    let connections = Int((item["connections"] as? String) ?? "0") ?? 0
    let errorCode = item["errorCode"] as? String
    let errorMessage = item["errorMessage"] as? String
    let displayName = [bittorrentDisplayName, pathName, magnetDisplayName]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty })

    return Aria2TaskSnapshot(
      gid: gid,
      status: status,
      totalBytes: totalBytes,
      completedBytes: completedBytes,
      downloadSpeed: downloadSpeed,
      connections: connections,
      fileName: pathName,
      displayName: displayName,
      errorMessage: errorCode == nil ? errorMessage : "[\(errorCode ?? "-")] \(errorMessage ?? "下载失败")"
    )
  }
}
