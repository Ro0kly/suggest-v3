//
//  ContentView5.swift
//  suggest
//
//  Created by Rookly on 14.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip5: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - Infinite Scroll Coordinator

class InfiniteScrollCoordinator: NSObject, UIScrollViewDelegate, ObservableObject {
    var scrollViews: [UIScrollView] = []
    private var isSyncing = false
    private var isUserScrolling = false
    private var resumeTask: DispatchWorkItem?

    // Content info per row - set after layout
    var singleSetWidths: [CGFloat] = []

    // Auto-scroll
    private var displayLink: CADisplayLink?
    let speeds: [CGFloat] = [-0.5, -0.8]

    func register(_ scrollView: UIScrollView, index: Int) {
        guard !scrollViews.contains(scrollView) else { return }

        while scrollViews.count <= index {
            scrollViews.append(UIScrollView())
            singleSetWidths.append(0)
        }
        if singleSetWidths.count <= index {
            singleSetWidths.append(0)
        }
        scrollViews[index] = scrollView
        scrollView.delegate = self
        scrollView.tag = index
        scrollView.bounces = false
    }

    func setupContentWidth() {
        for (index, scrollView) in scrollViews.enumerated() {
            if scrollView.contentSize.width > 0 {
                while singleSetWidths.count <= index {
                    singleSetWidths.append(0)
                }
                singleSetWidths[index] = scrollView.contentSize.width / 5 // 5 copies now
            }
        }
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
            guard index < singleSetWidths.count, singleSetWidths[index] > 0 else { continue }

            // Just move, don't normalize during animation
            let newX = scrollView.contentOffset.x - speeds[index]
            scrollView.contentOffset.x = newX

            // Check if we need to reposition (only at boundaries)
            let setWidth = singleSetWidths[index]
            if newX < setWidth * 0.5 || newX > setWidth * 3.5 {
                // Near edge - reposition to center
                scrollView.contentOffset.x = setWidth * 2
            }
        }
        isSyncing = false
    }

    func scrollToCenter() {
        isSyncing = true
        for (index, scrollView) in scrollViews.enumerated() {
            guard index < singleSetWidths.count, singleSetWidths[index] > 0 else { continue }
            // Start in middle (set index 2 of 5)
            scrollView.contentOffset.x = singleSetWidths[index] * 2
        }
        isSyncing = false
    }

    private func normalizeAllScrollViews() {
        isSyncing = true
        for (index, scrollView) in scrollViews.enumerated() {
            guard index < singleSetWidths.count else { continue }
            let setWidth = singleSetWidths[index]
            guard setWidth > 0 else { continue }

            let offset = scrollView.contentOffset.x

            // Keep in middle range (sets 1-3 of 0-4)
            if offset < setWidth {
                scrollView.contentOffset.x = offset + setWidth * 2
            } else if offset >= setWidth * 4 {
                scrollView.contentOffset.x = offset - setWidth * 2
            }
        }
        isSyncing = false
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
        resumeTask?.cancel()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            // Scroll stopped without momentum - normalize now
            normalizeAllScrollViews()
            scheduleResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Scroll fully stopped - normalize now
        normalizeAllScrollViews()
        scheduleResume()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing else { return }
        guard isUserScrolling else { return } // Only sync during user scroll

        let index = scrollView.tag
        guard index < singleSetWidths.count, singleSetWidths[index] > 0 else { return }

        isSyncing = true

        // Just sync, don't normalize during active scroll
        for (otherIndex, sv) in scrollViews.enumerated() where sv !== scrollView {
            guard otherIndex < singleSetWidths.count, singleSetWidths[otherIndex] > 0 else { continue }
            // Map the relative position from source to target
            let relativePosition = scrollView.contentOffset.x / singleSetWidths[index]
            sv.contentOffset.x = relativePosition * singleSetWidths[otherIndex]
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

struct ChipView5: View {
    let chip: Chip5

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

struct ChipRowView5: View {
    let chips: [Chip5]
    let index: Int
    let coordinator: InfiniteScrollCoordinator
    let onTap: (Chip5) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView5(chip: chip)
                        .onTapGesture {
                            onTap(chip)
                        }
                }
            }
            .padding(.horizontal)
        }
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            coordinator.register(scrollView, index: index)
        }
    }
}

// MARK: - ContentView5

struct ContentView5: View {
    // 5 copies for smoother infinite scroll
    private let repeatCount = 5
    private let baseRow1 = ["Check my balance", "Recent transactions", "Transfer money", "Pay bills", "Card limits"]
    private let baseRow2 = ["Open new account", "Exchange rates", "Find ATM nearby", "Block my card", "Loan calculator"]

    @State private var row1: [Chip5] = []
    @State private var row2: [Chip5] = []
    @StateObject private var coordinator = InfiniteScrollCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ChipRowView5(chips: row1, index: 0, coordinator: coordinator) { chip in
                print("Tapped: \(chip.text)")
            }

            ChipRowView5(chips: row2, index: 1, coordinator: coordinator) { chip in
                print("Tapped: \(chip.text)")
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            row1 = (0..<repeatCount).flatMap { repeatIndex in
                baseRow1.enumerated().map { index, text in
                    Chip5(text, index: repeatIndex * baseRow1.count + index)
                }
            }
            row2 = (0..<repeatCount).flatMap { repeatIndex in
                baseRow2.enumerated().map { index, text in
                    Chip5(text, index: repeatIndex * baseRow2.count + index)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                coordinator.setupContentWidth()
                coordinator.scrollToCenter()
                coordinator.startAutoScroll()
            }
        }
        .onDisappear {
            coordinator.stopAutoScroll()
        }
    }
}

#Preview {
    ContentView5()
}
