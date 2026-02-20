//
//  ContentView4point4.swift
//  suggest
//
//  Created by Rookly on 16.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip4p4: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target (weak proxy breaks CADisplayLink retain cycle)

private class DisplayLinkTarget {
    weak var behavior: ChipScrollBehavior?

    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - Chip Scroll Behavior

class ChipScrollBehavior: NSObject, UIScrollViewDelegate, ObservableObject {
    private var scrollViews: [Int: UIScrollView] = [:]
    private var rowSpeeds: [Int: CGFloat] = [:]
    private var isSyncing = false
    private var needsCentering = true

    // Drag state
    private var dragOriginX: CGFloat = 0
    private var allDragOrigins: [Int: CGFloat] = [:]

    // Auto-scroll
    private var displayLink: CADisplayLink?
    private var isUserScrolling = false
    private var resumeTask: Task<Void, Never>?

    // Tap filtering
    private var lastTapStopTime: CFTimeInterval = 0
    private let tapIgnoreWindow: CFTimeInterval = 0.3

    deinit {
        stop()
    }

    // MARK: - Public API

    func register(_ scrollView: UIScrollView, rowIndex: Int) {
        guard scrollViews[rowIndex] !== scrollView else { return }
        scrollViews[rowIndex] = scrollView
        scrollView.delegate = self
    }

    func start(rowCount: Int) {
        configureRowSpeeds(rowCount: rowCount)
        startDisplayLink()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    func shouldHandleTap() -> Bool {
        CACurrentMediaTime() - lastTapStopTime > tapIgnoreWindow
    }

    // MARK: - Configuration

    private func configureRowSpeeds(rowCount: Int) {
        if rowCount == 2 {
            rowSpeeds = [0: -0.5, 1: -0.8]
        } else {
            rowSpeeds = [0: -0.4, 1: -0.6, 2: -0.9]
        }
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func onFrame() {
        centerRowsIfNeeded()

        guard !isUserScrolling else { return }
        advanceAutoScroll()
    }

    private func centerRowsIfNeeded() {
        guard needsCentering else { return }

        let allReady = !scrollViews.isEmpty && scrollViews.values.allSatisfy {
            $0.contentSize.width > $0.bounds.width
        }
        guard allReady else { return }

        for sv in scrollViews.values {
            sv.contentOffset.x = (sv.contentSize.width - sv.bounds.width) / 2
        }
        needsCentering = false
    }

    private func advanceAutoScroll() {
        isSyncing = true
        for (index, scrollView) in scrollViews {
            guard let speed = rowSpeeds[index] else { continue }

            let newX = scrollView.contentOffset.x - speed
            let maxX = scrollView.contentSize.width - scrollView.bounds.width
            if newX >= 0 && newX <= maxX {
                scrollView.contentOffset.x = newX
            }
        }
        isSyncing = false
    }

    // MARK: - Resume After Interaction

    private func scheduleAutoScrollResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }

            let stillScrolling = scrollViews.values.contains {
                $0.isDragging || $0.isDecelerating
            }
            if !stillScrolling {
                isUserScrolling = false
            }
        }
    }

    // MARK: - Scroll Sync

    private func stopAllRows() {
        isSyncing = true
        for (_, sv) in scrollViews {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
        isSyncing = false
    }

    private func stopOtherRows(except scrollView: UIScrollView) {
        for (_, sv) in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
    }

    private func syncOtherRows(to scrollView: UIScrollView) {
        let delta = scrollView.contentOffset.x - dragOriginX

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = allDragOrigins[index] else { continue }
            let newX = startX + delta
            let maxX = sv.contentSize.width - sv.bounds.width
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }
    }

    private func anotherRowIsTracking(except scrollView: UIScrollView) -> Bool {
        scrollViews.values.contains { $0 !== scrollView && $0.isTracking }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()
        isUserScrolling = true
        stopOtherRows(except: scrollView)

        dragOriginX = scrollView.contentOffset.x
        allDragOrigins = scrollViews.mapValues { $0.contentOffset.x }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleAutoScrollResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleAutoScrollResume()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing, !allDragOrigins.isEmpty else { return }

        if anotherRowIsTracking(except: scrollView) {
            lastTapStopTime = CACurrentMediaTime()
            stopAllRows()
            scheduleAutoScrollResume()
            return
        }

        isSyncing = true
        syncOtherRows(to: scrollView)
        isSyncing = false
    }
}

// MARK: - Chip View

struct ChipView4p4: View {
    let chip: Chip4p4

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

struct ChipRowView4p4: View {
    let chips: [Chip4p4]
    let rowIndex: Int
    let behavior: ChipScrollBehavior
    let onTap: (Chip4p4) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4p4(chip: chip)
                        .onTapGesture {
                            guard behavior.shouldHandleTap() else { return }
                            onTap(chip)
                        }
                }
            }
        }
        .frame(height: 52)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            behavior.register(scrollView, rowIndex: rowIndex)
        }
    }
}

// MARK: - Main View

struct ContentView4point4: View {
    private let repeatCount = 30

//    private let backendChips = [
//        "Check my balance",
//        "Recent transactions",
//        "Transfer money",
//        "Pay bills",
//        "Card limits",
//        "Open new account",
//        "Exchange rates",
//        "Find ATM nearby",
//        "Block my card",
//        "Loan calculator"
//    ]
    
    private let backendChips = [
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "7",
        "8",
        "9",
        "10",
        "11",
        "12",
        "13",
        "14",
        "15",
        "16",
        "17",
    ]

    @State private var rows: [[Chip4p4]] = []
    @StateObject private var behavior = ChipScrollBehavior()

    private var rowCount: Int {
        backendChips.count < 15 ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                    ChipRowView4p4(chips: chips, rowIndex: index, behavior: behavior) { chip in
                        print("Tapped: \(chip.text)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            behavior.start(rowCount: rowCount)
        }
        .onDisappear {
            behavior.stop()
        }
    }

    private func setupRows() {
        var baseRows: [[String]] = []

        if backendChips.count < rowCount {
            for _ in 0..<rowCount {
                baseRows.append(backendChips)
            }
        } else {
            let chipsPerRow = Int(ceil(Double(backendChips.count) / Double(rowCount)))
            for rowIndex in 0..<rowCount {
                let startIndex = rowIndex * chipsPerRow
                let endIndex = min(startIndex + chipsPerRow, backendChips.count)
                baseRows.append(Array(backendChips[startIndex..<endIndex]))
            }
        }

        rows = baseRows.map { baseChips in
            (0..<repeatCount).flatMap { repeatIndex in
                baseChips.enumerated().map { chipIndex, text in
                    Chip4p4(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}
