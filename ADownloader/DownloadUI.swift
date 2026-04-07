//
//  DownloadUI.swift
//  ADownloader
//
//  Created by Codex on 4/7/26.
//

import SwiftUI

struct AddDownloadSheet: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isFocused: Bool
  @State private var sourceURL = ""

  let onSubmit: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("新建下载")
        .font(.title3.weight(.semibold))

      TextField("https://example.com/file.zip", text: $sourceURL)
        .autocorrectionDisabled()
        .focused($isFocused)
        .onSubmit(confirm)

      HStack {
        Spacer()

        Button("取消", role: .cancel) {
          dismiss()
        }

        Button("下一步", action: confirm)
          .buttonStyle(.borderedProminent)
          .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 520)
    .onAppear {
      isFocused = true
    }
  }

  private func confirm() {
    onSubmit(sourceURL)
    dismiss()
  }
}

struct ActiveDownloadCard: View {
  let task: DownloadTask
  let onPause: () -> Void
  let onResume: () -> Void
  let onCancel: () -> Void
  let onRetry: () -> Void

  var body: some View {
    DownloadCardContainer {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 18) {
          Text(task.displayName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)

          ProgressView(value: task.progress)
            .progressViewStyle(.linear)
            .tint(.indigo)

          HStack(alignment: .lastTextBaseline) {
            Text("\(task.completedBytes.byteString) / \(task.totalBytes.byteString)")
              .font(.title3.weight(.medium))
              .foregroundStyle(.secondary)

            Spacer(minLength: 24)

            Text("↓ \(task.downloadSpeed.speedString)")
              .font(.title3.weight(.medium))
              .foregroundStyle(.secondary)

            Text(task.remainingTimeText)
              .font(.title3.weight(.medium))
              .foregroundStyle(.secondary)

            Text("⎇ \(task.connections)")
              .font(.title3.weight(.medium))
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 10) {
          if task.status == .error {
            cardActionButton("重试", systemImage: "arrow.clockwise", action: onRetry)
          } else if task.status == .paused {
            cardActionButton("继续", systemImage: "play.fill", action: onResume)
          } else {
            cardActionButton("暂停", systemImage: "pause.fill", action: onPause)
          }

          cardActionButton("取消", systemImage: "xmark", action: onCancel)
        }
      }

      if let errorMessage = task.errorMessage, task.status == .error {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.red)
          .padding(.top, 8)
      }
    }
  }

  private func cardActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.title3)
        .frame(width: 46, height: 46)
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 23, style: .continuous)
        .fill(Color.white.opacity(0.92))
        .stroke(Color.black.opacity(0.06), lineWidth: 1)
    )
    .accessibilityLabel(title)
  }
}

struct CompletedDownloadCard: View {
  let task: DownloadTask
  let onOpen: () -> Void
  let onReveal: () -> Void

  var body: some View {
    DownloadCardContainer {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 14) {
          Text(task.displayName)
            .font(.title3.weight(.semibold))
            .lineLimit(2)

          Text(task.filePath)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

          HStack(spacing: 18) {
            Text(task.totalBytes.byteString)
            Text((task.completedAt ?? task.updatedAt).dateString)
          }
          .font(.callout)
          .foregroundStyle(.secondary)
        }

        Spacer(minLength: 16)

        HStack(spacing: 10) {
          cardActionButton("打开文件", systemImage: "doc", action: onOpen)
          cardActionButton("在 Finder 中显示", systemImage: "folder", action: onReveal)
        }
      }
    }
  }

  private func cardActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.title3)
        .frame(width: 46, height: 46)
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 23, style: .continuous)
        .fill(Color.white.opacity(0.92))
        .stroke(Color.black.opacity(0.06), lineWidth: 1)
    )
    .accessibilityLabel(title)
  }
}

struct DownloadCardContainer<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .padding(28)
    .background(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .fill(.white)
        .stroke(Color.black.opacity(0.06), lineWidth: 1)
        .shadow(color: .black.opacity(0.05), radius: 20, y: 10)
    )
  }
}

struct DownloadEmptyState: View {
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "tray")
        .font(.system(size: 30))
        .foregroundStyle(.secondary)

      Text(title)
        .font(.title3.weight(.semibold))

      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private extension Int64 {
  var byteString: String {
    ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
  }

  var speedString: String {
    "\(ByteCountFormatter.string(fromByteCount: self, countStyle: .file))/s"
  }
}

private extension Date {
  var dateString: String {
    formatted(date: .abbreviated, time: .shortened)
  }
}

private extension DownloadTask {
  var remainingTimeText: String {
    guard downloadSpeed > 0, totalBytes > completedBytes else { return "剩余 --" }
    let seconds = max(Int((totalBytes - completedBytes) / downloadSpeed), 0)
    guard seconds > 0 else { return "剩余 <1s" }

    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return "剩余 \(formatter.string(from: TimeInterval(seconds)) ?? "--")"
  }
}
