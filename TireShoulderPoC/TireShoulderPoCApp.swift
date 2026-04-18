//
//  TireShoulderPoCApp.swift
//  TireShoulderPoC
//
//  Created by Kenichi Takei on 2026/04/18.
//

import SwiftUI

@main
struct TireShoulderPoCApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
    }
}
