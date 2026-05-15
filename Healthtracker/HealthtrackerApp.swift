//
//  HealthtrackerApp.swift
//  Healthtracker
//
//  Created by Jorrawar Grewal on 5/11/26.
//

import SwiftUI

@main
struct HealthtrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("-WipeCache") {
                        await CGMReportCache().deleteFile()
                        print("[Cache] Wiped.")
                    }
                    await DevHealthKitInjector().injectIfLaunchArgPresent()
                    #endif
                }
        }
    }
}
