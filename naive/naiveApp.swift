//
//  naiveApp.swift
//  naive
//
//  Created by Nick Bai on 5/2/26.
//

import SwiftUI

@main
struct naiveApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 820, height: 700)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
    }
}
