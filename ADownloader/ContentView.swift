//
//  ContentView.swift
//  ADownloader
//
//  Created by Changlin on 4/2/26.
//

import SwiftUI

struct ContentView: View {
  var body: some View {
    NavigationSplitView {
      List {

      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
      .toolbar {
        ToolbarItem {
          Button(action: addItem) {
            Label("Add", systemImage: "plus")
          }
        }
      }
    } detail: {
      Text("Select an item")
    }
    .background(MainWindowAccessor())
  }

  private func addItem() {

  }
}

#Preview {
  ContentView()
}
