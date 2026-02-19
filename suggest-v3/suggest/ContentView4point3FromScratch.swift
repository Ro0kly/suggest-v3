//
//  ContentView4point3FromScratch.swift
//  suggest
//

import SwiftUI
import UIKit

struct ChipFS: Identifiable {
     let id: String
     let text: String

     init(_ text: String, index: Int) {
         self.id = "\(text)-\(index)"
         self.text = text
     }
 }

struct ChipViewFS: View {
    let chip: ChipFS

    var body: some View {
        Text(chip.text)
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.15))
            .foregroundColor(.blue)
            .cornerRadius(20)
    }
}

struct ChipRowViewFS: View {
    let chips: [ChipFS]
    let rowIndex: Int
    let behavior: ChipScrollBehaviorFS

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipViewFS(chip: chip)
                }
            }
        }
        .frame(height: 52)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            behavior.register(scrollView, rowIndex: rowIndex)
        }
    }
}

struct ContentViewFromScratch: View {
    private let repeatCount = 3
    
    private let backendChips = [
        "Check balance", "Recent transactions", "Transfer money",
        "Pay bills", "Card limits", "Open account",
        "Exchange rates", "Find ATM", "Block card", "Loan calculator"
    ]
    
    @State private var rows: [[ChipFS]] = []
    @StateObject private var behavior = ChipScrollBehaviorFS()
    
    private var rowCount: Int {
        backendChips.count < 15 ? 2 : 3
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2).fontWeight(.bold).padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                    ChipRowViewFS(chips: chips, rowIndex: index, behavior: behavior)
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            behavior.start()
        }
        .onDisappear {
            behavior.stop()
        }
    }
    
    private func setupRows() {
        var baseRows: [[String]] = []
        
        if backendChips.count <= 3 {
            baseRows = Array(repeating: backendChips, count: rowCount)
        } else {
            let perRow = Int(ceil(Double(backendChips.count) / Double(rowCount)))
             for i in 0..<rowCount {
                 let s = i * perRow
                 baseRows.append(Array(backendChips[s..<min(s + perRow, backendChips.count)]))
             }
        }
        
        rows = baseRows.map { base in
            (0..<repeatCount).flatMap { r in
                base.enumerated().map { i, text in
                    ChipFS(text, index: r * base.count + i)
                }
            }
        }
    }
}

private class DisplayLinkTargetFS {
    weak var behavior: ChipScrollBehaviorFS?
    
    @objc func tick() {
        behavior?.onFrame()
    }
}

class ChipScrollBehaviorFS: NSObject, UIScrollViewDelegate, ObservableObject {
    
    private var scrollViews: [Int: UIScrollView] = [:]
    
    private var displayLink: CADisplayLink?
    
    private var rowSpeeds: [Int: CGFloat] = [:]
    
    private var isUserScrolling = false
    
    func register(_ scrollView: UIScrollView, rowIndex: Int) {
        guard scrollViews[rowIndex] != scrollView else { return }
        scrollViews[rowIndex] = scrollView
        scrollView.delegate = self
        scrollView.tag = rowIndex
    }
    
    func start() {
        guard displayLink == nil else { return }
        
//        rowSpeeds = rowCount == 2
//            ? [0: -0.5, 1: -0.8]
//            : [0: -0.4, 1: -0.6, 2: -0.9]
//
        let target = DisplayLinkTargetFS()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTargetFS.tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    func onFrame() {
        
    }
}
