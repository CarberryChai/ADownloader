//
//  ADownloaderApp.swift
//  ADownloader
//
//  Created by Changlin on 4/2/26.
//

import AppKit
import SwiftData
import SwiftUI

@main
struct ADownloaderApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  private let sharedModelContainer: ModelContainer = {
    let schema = Schema([
      DownloadTask.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

    do {
      return try ModelContainer(for: schema, configurations: [configuration])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }
  }()

  var body: some Scene {
    Window("ADownloader", id: WindowCoordinator.mainWindowID) {
      ContentView()
    }
    .modelContainer(sharedModelContainer)

    Settings {
      Text("hello")
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MenuBarController.shared.install()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

final class MenuBarController: NSObject {
  static let shared = MenuBarController()

  private var statusItem: NSStatusItem?

  func install() {
    guard statusItem == nil else { return }

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "ADownloader")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(handleClick)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

    self.statusItem = statusItem
  }

  @objc private func handleClick() {
    WindowCoordinator.shared.showMainWindow()
  }
}

final class WindowCoordinator: NSObject, NSWindowDelegate {
  static let mainWindowID = "ADownloader"
  static let shared = WindowCoordinator()

  weak var mainWindow: NSWindow?

  func register(_ window: NSWindow) {
    guard mainWindow !== window else { return }

    mainWindow = window
    window.delegate = self
  }

  func showMainWindow() {
    guard let mainWindow else { return }

    if !mainWindow.isVisible {
      mainWindow.orderFrontRegardless()
    }

    NSApp.activate(ignoringOtherApps: true)
    mainWindow.makeKeyAndOrderFront(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === mainWindow else { return true }

    sender.orderOut(nil)
    return false
  }
}

struct MainWindowAccessor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    attachWindow(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    attachWindow(to: nsView)
  }

  private func attachWindow(to view: NSView) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      WindowCoordinator.shared.register(window)
    }
  }
}
