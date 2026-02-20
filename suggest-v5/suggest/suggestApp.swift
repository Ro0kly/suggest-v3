//
//  suggestApp.swift
//  suggest
//
//  Created by Rookly on 14.02.2026.
//

import SwiftUI

@main
struct suggestApp: App {
    var body: some Scene {
        WindowGroup {
//            ContentViewSingleScrollNoDragGesture()
//            ContentView2()
            ContentView4point3(chips: [
                "Check balance", "Recent transactions", "Transfer money",
                "Pay bills", "Card limits", "Open account",
                "Exchange rates", "Find ATM", "Block card", "Loan calculator"
            ].enumerated().map { i, text in
                Chip4p3(text, index: i, onTap: { print("Tapped: \(text)") })
            })
//            ContentViewFromScratch()
        }
    }
}
