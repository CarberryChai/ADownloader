//
//  ContentView.swift
//  ADownloader
//
//  Created by Changlin on 4/2/26.
//

import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var isPresentingAddSheet = false
  @State private var store = DownloadStore()

  var body: some View {
    @Bindable var store = store

    NavigationSplitView {
      List(DownloadSidebar.allCases, selection: $store.selectedSidebar) { sidebar in
        Label {
          HStack {
            Text(sidebar.title)
            Spacer()
            Text(sidebar == .active ? "\(store.activeTasks.count)" : "\(store.completedTasks.count)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: sidebar.systemImage)
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    } detail: {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          switch store.selectedSidebar {
          case .active:
            if store.activeTasks.isEmpty {
              DownloadEmptyState(
                title: "没有进行中的任务",
                message: "点击右上角 Add，输入链接后开始下载。"
              )
              .frame(minHeight: 320)
            } else {
              ForEach(store.activeTasks) { task in
                ActiveDownloadCard(
                  task: task,
                  onPause: { Task { await store.pause(task) } },
                  onResume: { Task { await store.resume(task) } },
                  onCancel: { Task { await store.cancel(task) } },
                  onRetry: { Task { await store.retry(task) } }
                )
              }
            }

          case .completed:
            if store.completedTasks.isEmpty {
              DownloadEmptyState(
                title: "还没有已完成的任务",
                message: "下载完成的文件会出现在这里。"
              )
              .frame(minHeight: 320)
            } else {
              ForEach(store.completedTasks) { task in
                CompletedDownloadCard(
                  task: task,
                  onOpen: { store.openFile(for: task) },
                  onReveal: { store.revealFile(for: task) }
                )
              }
            }
          }
        }
        .padding(24)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .navigationTitle(store.selectedSidebar.title)
    .toolbar {
      ToolbarItem {
        Button(action: addTask) {
          Label("Add", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $isPresentingAddSheet) {
      AddDownloadSheet { sourceURL in
        guard let directoryURL = selectDownloadDirectory() else { return }
        Task {
          await store.addDownload(sourceURLString: sourceURL, directoryURL: directoryURL)
        }
      }
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { store.alertMessage != nil },
        set: { if !$0 { store.clearAlert() } }
      )
    ) {
      Button("好", role: .cancel) {
        store.clearAlert()
      }
    } message: {
      Text(store.alertMessage ?? "")
    }
    .task {
      store.configure(modelContext: modelContext)
    }
    .background(MainWindowAccessor())
  }

  private func addTask() {
    isPresentingAddSheet = true
  }

  private func selectDownloadDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.message = "请选择下载保存目录。"
    return panel.runModal() == .OK ? panel.url : nil
  }
}

#Preview {
  ContentView()
    .modelContainer(for: DownloadTask.self, inMemory: true)
}
