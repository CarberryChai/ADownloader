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
  @State private var pendingSourceURL: String?
  @State private var store = DownloadStore()

  var body: some View {
    @Bindable var store = store

    NavigationSplitView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(DownloadSidebar.allCases) { sidebar in
          Button {
            store.selectedSidebar = sidebar
          } label: {
            HStack {
              Label(sidebar.title, systemImage: sidebar.systemImage)
              Spacer()
              Text("\(sidebarCount(for: sidebar, store: store))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(sidebar == store.selectedSidebar ? Color.accentColor.opacity(0.14) : .clear)
          )
        }
        Spacer()
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .controlBackgroundColor))
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

          case .trash:
            if store.removedTasks.isEmpty {
              DownloadEmptyState(
                title: "回收站是空的",
                message: "删除的下载任务会出现在这里。"
              )
              .frame(minHeight: 320)
            } else {
              ForEach(store.removedTasks) { task in
                TrashDownloadCard(
                  task: task,
                  onDelete: { store.permanentlyDelete(task) }
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
        pendingSourceURL = sourceURL
      }
    }
    .onChange(of: isPresentingAddSheet) { _, isPresented in
      guard !isPresented, let sourceURL = pendingSourceURL else { return }
      pendingSourceURL = nil

      Task { @MainActor in
        guard let directoryURL = selectDownloadDirectory() else { return }
        let didAddTask = await store.addDownload(sourceURLString: sourceURL, directoryURL: directoryURL)
        if didAddTask, store.selectedSidebar != .active {
          store.selectedSidebar = .active
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

  private func sidebarCount(for sidebar: DownloadSidebar, store: DownloadStore) -> Int {
    switch sidebar {
    case .active:
      store.activeTasks.count
    case .completed:
      store.completedTasks.count
    case .trash:
      store.removedTasks.count
    }
  }
}

#Preview {
  ContentView()
    .modelContainer(for: DownloadTask.self, inMemory: true)
}
