//
//  ContentView4point2.swift
//  suggest
//
//  Created by Rookly on 15.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip4p2: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - Scroll Coordinator

class ScrollCoordinator4p2: NSObject, UIScrollViewDelegate, ObservableObject {
    var scrollViews: [UIScrollView] = []
    private var isSyncing = false
    private var dragStartOffsets: [CGFloat] = []
    private var dragStartOffset: CGFloat = 0
    var justStoppedScroll = false

    // Auto-scroll
    private var displayLink: CADisplayLink?
    private var speeds: [CGFloat] = []
    private var isUserInteracting = false
    private var resumeTask: Task<Void, Never>?

    func register(_ scrollView: UIScrollView, index: Int) {
        guard !scrollViews.contains(scrollView) else { return }

        while scrollViews.count <= index {
            scrollViews.append(UIScrollView())
        }
        scrollViews[index] = scrollView
        scrollView.delegate = self
        scrollView.tag = index
    }

    func configureSpeeds(rowCount: Int) {
        speeds = Array(repeating: 0, count: rowCount)

        // Разные скорости для каждой row
        if rowCount == 2 {
            speeds = [-0.5, -0.8]
        } else {
            speeds = [-0.4, -0.6, -0.9]
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
        guard !isUserInteracting else { return }

        isSyncing = true
        for (index, scrollView) in scrollViews.enumerated() where index < speeds.count {
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

    private func scheduleResume() {
        // Отменяем предыдущую задачу
        resumeTask?.cancel()

        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 секунды

            // Проверяем не отменили ли
            guard !Task.isCancelled else { return }

            // Проверяем состояние - не скроллится ли что-то
            let anyScrolling = scrollViews.contains {
                $0.isDragging || $0.isDecelerating
            }

            if !anyScrolling {
                isUserInteracting = false
            }
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()  // Отменяем задержку
        isUserInteracting = true  // Останавливаем автоскролл
        justStoppedScroll = false  // Сбрасываем флаг при новом drag

        // Останавливаем deceleration всех остальных scroll views
        for sv in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }

        // Store starting positions for delta-based sync
        dragStartOffset = scrollView.contentOffset.x
        dragStartOffsets = scrollViews.map { $0.contentOffset.x }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            // User отпустил, инерции нет - запускаем задержку
            scheduleResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // Инерция закончилась - запускаем задержку
        scheduleResume()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing else { return }
        guard !dragStartOffsets.isEmpty else { return }

        for sv in scrollViews where sv !== scrollView {
            if sv.isTracking {
                // Останавливаем deceleration всех scroll views
                isSyncing = true
                justStoppedScroll = true  // Устанавливаем флаг
                for otherSV in scrollViews {
                    otherSV.setContentOffset(otherSV.contentOffset, animated: false)
                }
                isSyncing = false

                // Запускаем задержку для возобновления автоскролла
                scheduleResume()
                return
            }
        }

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
}

// MARK: - Chip View

struct ChipView4p2: View {
    let chip: Chip4p2

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

struct ChipRowView4p2: View {
    let chips: [Chip4p2]
    let index: Int
    let coordinator: ScrollCoordinator4p2
    let onTap: (Chip4p2) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4p2(chip: chip)
                        .onTapGesture {
                            // Если только что остановили scroll тапом - игнорируем
                            guard !coordinator.justStoppedScroll else {
                                coordinator.justStoppedScroll = false
                                return
                            }

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

// MARK: - ContentView4point2

struct ContentView4point2: View {
    private let repeatCount = 30

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

    @State private var rows: [[Chip4p2]] = []
    @StateObject private var coordinator = ScrollCoordinator4p2()

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
                    ChipRowView4p2(chips: chips, index: index, coordinator: coordinator) { chip in
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
        let chipsPerRow = Int(ceil(Double(backendChips.count) / Double(rowCount)))
        var baseRows: [[String]] = []

        for rowIndex in 0..<rowCount {
            let startIndex = rowIndex * chipsPerRow
            let endIndex = min(startIndex + chipsPerRow, backendChips.count)
            if startIndex < backendChips.count {
                baseRows.append(Array(backendChips[startIndex..<endIndex]))
            }
        }

        rows = baseRows.enumerated().map { _, baseChips in
            (0..<repeatCount).flatMap { repeatIndex in
                baseChips.enumerated().map { chipIndex, text in
                    Chip4p2(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}

#Preview {
    ContentView4point2()
}
