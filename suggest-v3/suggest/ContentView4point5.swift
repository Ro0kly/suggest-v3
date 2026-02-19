//
//  ContentView4point5.swift
//  suggest
//
//  Created by Rookly on 16.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip4p5: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Proxy (breaks CADisplayLink → Coordinator retain cycle)

private class DisplayLinkProxy4p5 {
    weak var coordinator: ScrollCoordinator4p5?

    @objc func tick() {
        coordinator?.displayLinkTick()
    }
}

// MARK: - Scroll Coordinator

class ScrollCoordinator4p5: NSObject, UIScrollViewDelegate, ObservableObject {
    private var scrollViews: [Int: UIScrollView] = [:]
    private var isSyncing = false
    private var dragStartOffsets: [Int: CGFloat] = [:]
    private var dragStartOffset: CGFloat = 0
    private var draggedIndex: Int?

    // Tap filtering
    private var lastScrollStopTime: CFTimeInterval = 0
    private let tapIgnoreThreshold: CFTimeInterval = 0.3

    // Auto-scroll
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy4p5?
    private var speeds: [Int: CGFloat] = [:]
    private var isUserInteracting = false
    private var resumeTask: Task<Void, Never>?
    private var needsInitialCenter = true

    deinit {
        stopAutoScroll()
        resumeTask?.cancel()
    }

    // MARK: - Registration

    func register(_ scrollView: UIScrollView, index: Int) {
        guard scrollViews[index] !== scrollView else { return }
        scrollViews[index] = scrollView
        scrollView.delegate = self
        scrollView.tag = index
    }

    // MARK: - Configuration

    func configureSpeeds(rowCount: Int) {
        if rowCount == 2 {
            speeds = [0: -0.5, 1: -0.8]
        } else {
            speeds = [0: -0.4, 1: -0.6, 2: -0.9]
        }
    }

    // MARK: - Auto-scroll

    func startAutoScroll() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy4p5()
        proxy.coordinator = self
        displayLinkProxy = proxy
        displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy4p5.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    func displayLinkTick() {
        // Center all rows once layout is ready
        if needsInitialCenter {
            let allReady = !scrollViews.isEmpty && scrollViews.values.allSatisfy {
                $0.contentSize.width > $0.bounds.width
            }
            if allReady {
                for sv in scrollViews.values {
                    sv.contentOffset.x = (sv.contentSize.width - sv.bounds.width) / 2
                }
                needsInitialCenter = false
            }
        }

        guard !isUserInteracting else { return }

        isSyncing = true
        for (index, scrollView) in scrollViews {
            guard let speed = speeds[index] else { continue }
            var offset = scrollView.contentOffset
            offset.x -= speed

            let maxX = scrollView.contentSize.width - scrollView.bounds.width
            if offset.x >= 0 && offset.x <= maxX {
                scrollView.contentOffset = offset
            }
        }
        isSyncing = false
    }

    // MARK: - Tap handling

    func shouldHandleTap() -> Bool {
        CACurrentMediaTime() - lastScrollStopTime > tapIgnoreThreshold
    }

    // MARK: - Resume logic

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            let anyScrolling = scrollViews.values.contains {
                $0.isDragging || $0.isDecelerating
            }
            if !anyScrolling {
                isUserInteracting = false
            }
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()
        isUserInteracting = true
        draggedIndex = scrollView.tag

        // Kill deceleration on all other scroll views
        for (_, sv) in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }

        dragStartOffset = scrollView.contentOffset.x
        dragStartOffsets = scrollViews.mapValues { $0.contentOffset.x }
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
        guard !dragStartOffsets.isEmpty else { return }

        // Detect tap-to-stop on another row
        for (_, sv) in scrollViews where sv !== scrollView {
            if sv.isTracking {
                isSyncing = true
                lastScrollStopTime = CACurrentMediaTime()
                for (_, otherSV) in scrollViews {
                    otherSV.setContentOffset(otherSV.contentOffset, animated: false)
                }
                isSyncing = false
                scheduleResume()
                return
            }
        }

        // Speed-ratio sync: each row moves proportionally to its auto-scroll speed
        guard let dragIdx = draggedIndex,
              let draggedSpeed = speeds[dragIdx],
              draggedSpeed != 0 else { return }

        isSyncing = true
        let delta = scrollView.contentOffset.x - dragStartOffset

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = dragStartOffsets[index] else { continue }
            guard let targetSpeed = speeds[index] else { continue }

            let ratio = abs(targetSpeed) / abs(draggedSpeed)
            let newX = startX + delta * ratio
            let maxX = sv.contentSize.width - sv.bounds.width
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }
        isSyncing = false
    }
}

// MARK: - Chip View

struct ChipView4p5: View {
    let chip: Chip4p5

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

struct ChipRowView4p5: View {
    let chips: [Chip4p5]
    let index: Int
    let coordinator: ScrollCoordinator4p5
    let onTap: (Chip4p5) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4p5(chip: chip)
                        .onTapGesture {
                            guard coordinator.shouldHandleTap() else { return }
                            onTap(chip)
                        }
                }
            }
        }
        .frame(height: 52)
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            coordinator.register(scrollView, index: index)
        }
    }
}

// MARK: - Main View

struct ContentView4point5: View {
    private let repeatCount = 20

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
        "Loan calculator"
    ]

    @State private var rows: [[Chip4p5]] = []
    @StateObject private var coordinator = ScrollCoordinator4p5()

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
                    ChipRowView4p5(chips: chips, index: index, coordinator: coordinator) { chip in
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
            coordinator.startAutoScroll()
        }
        .onDisappear {
            coordinator.stopAutoScroll()
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
                    Chip4p5(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}
