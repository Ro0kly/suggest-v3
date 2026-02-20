//
//  ContentView4.swift
//  suggest
//
//  Created by Rookly on 14.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip4: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - Scroll Coordinator

class ScrollCoordinator4: NSObject, UIScrollViewDelegate, ObservableObject {
    var scrollViews: [UIScrollView] = []
    private var isSyncing = false
    private var isUserScrolling = false
    private var resumeTask: DispatchWorkItem?
    private var dragStartOffsets: [CGFloat] = []
    private var dragStartOffset: CGFloat = 0

    // Auto-scroll
    private var displayLink: CADisplayLink?
    private var autoOffsets: [CGFloat] = []
    private var speeds: [CGFloat] = []

    func configureSpeeds(rowCount: Int) {
        speeds = Array(repeating: 0, count: rowCount)
        autoOffsets = Array(repeating: 0, count: rowCount)

        // Different speeds per row
        if rowCount == 2 {
            speeds = [-0.5, -0.8]
        } else {
            speeds = [-0.4, -0.6, -0.9]
        }
    }

    func register(_ scrollView: UIScrollView, index: Int) {
        guard !scrollViews.contains(scrollView) else { return }

        while scrollViews.count <= index {
            scrollViews.append(UIScrollView())
        }
        scrollViews[index] = scrollView
        scrollView.delegate = self
        scrollView.tag = index
    }

    func startAutoScroll() {
        guard displayLink == nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(autoScrollTick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func autoScrollTick() {
        guard !isUserScrolling else { return }

        isSyncing = true
        for (index, scrollView) in scrollViews.enumerated() where index < speeds.count {
            autoOffsets[index] += speeds[index]
            var newOffset = scrollView.contentOffset
            newOffset.x -= speeds[index]

            // Bounds check
            let maxX = scrollView.contentSize.width - scrollView.bounds.width
            if newOffset.x >= 0 && newOffset.x <= maxX {
                scrollView.contentOffset = newOffset
            }
        }
        isSyncing = false
    }

    func scrollToCenter() {
        isSyncing = true
        for scrollView in scrollViews {
            let centerX = (scrollView.contentSize.width - scrollView.bounds.width) / 2
            if centerX > 0 {
                scrollView.contentOffset.x = centerX
            }
        }
        isSyncing = false
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
        resumeTask?.cancel()

        // Store starting positions for delta-based sync
        dragStartOffset = scrollView.contentOffset.x
        dragStartOffsets = scrollViews.map { $0.contentOffset.x }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleResume()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing else { return }
        guard isUserScrolling else { return }
        guard !dragStartOffsets.isEmpty else { return }

        isSyncing = true

        // Calculate delta from drag start and apply to all rows
        let delta = scrollView.contentOffset.x - dragStartOffset

        for (index, sv) in scrollViews.enumerated() where sv !== scrollView {
            guard index < dragStartOffsets.count else { continue }

            let newX = dragStartOffsets[index] + delta
            let maxX = sv.contentSize.width - sv.bounds.width

            // Bounds check
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }

        isSyncing = false
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.isUserScrolling = false
        }
        resumeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
    }
}

// MARK: - Chip View

struct ChipView4: View {
    let chip: Chip4

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

// MARK: - Chip Row View

struct ChipRowView4: View {
    let chips: [Chip4]
    let index: Int
    let coordinator: ScrollCoordinator4
    let onTap: (Chip4) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4(chip: chip)
                        .onTapGesture {
                            onTap(chip)
                        }
                }
            }
        }
        .frame(height: 52)
//        .background(Color.red)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            coordinator.register(scrollView, index: index)
        }
        .onAppear {
            print(chips.count)
        }
    }
}

// MARK: - ContentView4

struct ContentView4: View {
    private let repeatCount = 30

    // Simulated backend data - single array
    private let backendChips = [
        "Check my balance",
        "Recent transactions",
        "Transfer money",
        "Pay bills",
        "Card limits",
        "Open new account",
        "Exchange rates",
        "Find ATM nearby",
        "Block my card",
        "Loan calculator",
        "Investment options",
        "Credit score",
        "Savings goals",
        "Direct deposit",
        "Wire transfer",
        "Mobile check deposit",
        "Account statements",
        "Tax documents",
        "Rewards program",
        "Contact support"
    ]

    @State private var rows: [[Chip4]] = []
    @StateObject private var coordinator = ScrollCoordinator4()

    private var rowCount: Int {
        backendChips.count < 15 ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                    ChipRowView4(chips: chips, index: index, coordinator: coordinator) { chip in
                        print("Tapped: \(chip.text)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            coordinator.configureSpeeds(rowCount: rowCount)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                coordinator.scrollToCenter()
                coordinator.startAutoScroll()
            }
        }
        .onDisappear {
            coordinator.stopAutoScroll()
        }
    }

    private func setupRows() {
        // Distribute chips to rows sequentially (1-5 to row 1, 6-10 to row 2, etc.)
        let chipsPerRow = Int(ceil(Double(backendChips.count) / Double(rowCount)))
        var baseRows: [[String]] = []

        for rowIndex in 0..<rowCount {
            let startIndex = rowIndex * chipsPerRow
            let endIndex = min(startIndex + chipsPerRow, backendChips.count)
            if startIndex < backendChips.count {
                baseRows.append(Array(backendChips[startIndex..<endIndex]))
            }
        }

        // Create repeated chips for infinity effect
        rows = baseRows.enumerated().map { rowIndex, baseChips in
            (0..<repeatCount).flatMap { repeatIndex in
                baseChips.enumerated().map { chipIndex, text in
                    Chip4(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}

#Preview {
    ContentView4()
}
