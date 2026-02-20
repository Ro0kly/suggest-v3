//
//  ContentView2.swift
//  suggest
//
//  Эксперимент: родительский ScrollView + дочерние disabled ScrollView + авто-скролл
//

import SwiftUI
import SwiftUIIntrospect

struct Chip: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target

private class DisplayLinkTarget2 {
    weak var behavior: AutoScrollBehavior2?

    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - Авто-скролл

class AutoScrollBehavior2: NSObject, UIScrollViewDelegate, ObservableObject {
    private weak var parentScrollView: UIScrollView?
    private var childScrollViews: [Int: UIScrollView] = [:]
    private var displayLink: CADisplayLink?
    private let speeds: [CGFloat] = [-0.5, -0.8]
    private var isUserScrolling = false
    private var resumeTask: Task<Void, Never>?
    private var needsCentering = true
    private var repeatCount = 30
    private var chipSpacing: CGFloat = 10

    // -- Синхронизация скоростей при юзер-скролле --
    /// Предыдущий offset parent'а для расчёта дельты
    private var lastParentOffsetX: CGFloat = 0
    /// Флаг: идёт программное изменение offset (не применять speed-ratio)
    private var isSyncing = false
    /// Отношение скорости каждой строки к средней (для юзер-скролла)
    private var speedRatios: [Int: CGFloat] = [:]

    deinit { stop() }

    func registerParent(_ scrollView: UIScrollView) {
        guard parentScrollView !== scrollView else { return }
        parentScrollView = scrollView
        scrollView.delegate = self
    }

    func registerChild(_ scrollView: UIScrollView, row: Int) {
        guard childScrollViews[row] !== scrollView else { return }
        // Защита: Introspect в nested ScrollView может найти parent вместо child
        guard scrollView !== parentScrollView else { return }
        childScrollViews[row] = scrollView
        scrollView.isScrollEnabled = false
    }

    func start(repeatCount: Int, chipSpacing: CGFloat) {
        self.repeatCount = repeatCount
        self.chipSpacing = chipSpacing
        configureSpeedRatios()
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget2()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget2.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func configureSpeedRatios() {
        let avgSpeed = speeds.reduce(0) { $0 + abs($1) } / CGFloat(speeds.count)
        guard avgSpeed > 0 else { return }
        for (i, speed) in speeds.enumerated() {
            speedRatios[i] = abs(speed) / avgSpeed
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    func onFrame() {
        // SwiftUI может пересоздать UIScrollView — гарантируем что дети выключены
        for (_, sv) in childScrollViews {
            if sv.isScrollEnabled { sv.isScrollEnabled = false }
        }

        centerIfNeeded()
        repositionParentIfNeeded()

        guard !isUserScrolling else { return }

        for (row, sv) in childScrollViews {
            guard row < speeds.count else { continue }
            sv.contentOffset.x -= speeds[row]
            repositionChildIfNeeded(sv)
        }
    }

    // MARK: - Центрирование (один раз при старте)

    private func centerIfNeeded() {
        guard needsCentering else { return }
        guard let parent = parentScrollView,
              parent.contentSize.width > parent.bounds.width else { return }

        isSyncing = true
        parent.contentOffset.x = (parent.contentSize.width - parent.bounds.width) / 2
        lastParentOffsetX = parent.contentOffset.x
        isSyncing = false
        needsCentering = false
    }

    // MARK: - Бесконечный скролл (родительский ScrollView)

    private func repositionParentIfNeeded() {
        guard let sv = parentScrollView, !sv.isTracking else { return }
        let contentWidth = sv.contentSize.width
        let boundsWidth = sv.bounds.width
        guard contentWidth > boundsWidth, repeatCount > 0 else { return }

        let period = (contentWidth + chipSpacing) / CGFloat(repeatCount)
        let maxOffset = contentWidth - boundsWidth
        guard period > 0, maxOffset > period else { return }

        // Пороги вокруг центра — после прыжка новая позиция гарантированно
        // внутри допустимого диапазона, без осцилляций даже при repeatCount=3
        let center = maxOffset / 2
        var adjustment: CGFloat = 0
        if sv.contentOffset.x > center + period / 2 {
            adjustment = -period
        } else if sv.contentOffset.x < center - period / 2 {
            adjustment = period
        }

        if adjustment != 0 {
            isSyncing = true
            sv.contentOffset.x += adjustment
            lastParentOffsetX = sv.contentOffset.x
            // Компенсируем каждого ребёнка: сдвигаем contentOffset
            // на обратную величину, чтобы визуальная позиция не менялась.
            // Затем оборачиваем по собственному периоду ребёнка.
            for (_, child) in childScrollViews {
                child.contentOffset.x -= adjustment
                repositionChildIfNeeded(child)
            }
            isSyncing = false
        }
    }

    // MARK: - Бесконечный скролл (дочерние ScrollView)

    private func repositionChildIfNeeded(_ sv: UIScrollView) {
        let contentWidth = sv.contentSize.width
        guard contentWidth > 0, repeatCount > 0 else { return }

        let period = (contentWidth + chipSpacing) / CGFloat(repeatCount)
        guard period > 0 else { return }

        // Оборачиваем в пределах [-period/2, period/2) — минимальный offset,
        // чтобы при repeatCount=3 хватало запаса от края контента
        let half = period / 2
        while sv.contentOffset.x > half {
            sv.contentOffset.x -= period
        }
        while sv.contentOffset.x < -half {
            sv.contentOffset.x += period
        }
    }

    // MARK: - UIScrollViewDelegate (родительский ScrollView)

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
        resumeTask?.cancel()
        lastParentOffsetX = scrollView.contentOffset.x
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing, scrollView === parentScrollView else { return }

        // Дельта скролла parent'а
        let delta = scrollView.contentOffset.x - lastParentOffsetX
        lastParentOffsetX = scrollView.contentOffset.x
        guard abs(delta) > 0.01 else { return }

        // Каждая строка двигается пропорционально своей скорости:
        // parent уже дал delta всем строкам одинаково,
        // child.offset корректирует разницу (ratio - 1)
        for (row, sv) in childScrollViews {
            guard let ratio = speedRatios[row] else { continue }
            sv.contentOffset.x += delta * (ratio - 1)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleResume()
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isUserScrolling = false
        }
    }
}

// MARK: - Вью чипа

struct ChipView2: View {
    let chip: Chip

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

// MARK: - Строка чипов (дочерний disabled ScrollView)

struct ChipRowView2: View {
    let chips: [Chip]
    let rowIndex: Int
    let behavior: AutoScrollBehavior2

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView2(chip: chip)
                        .onTapGesture {
                            print("Tapped: \(chip.text)")
                        }
                }
            }
        }
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
            behavior.registerChild(scrollView, row: rowIndex)
        }
    }
}

// MARK: - Главная вью

struct ContentView2: View {
    private let repeatCount = 3

    private let backendChips = [
        "Check balance",
        "Recent transactions",
        "Transfer money",
        "Pay bills",
        "Card limits",
        "Open account",
        "Exchange rates",
        "Find ATM",
        "Block card",
        "Loan calculator"
    ]

    @State private var rows: [[Chip]] = []
    @StateObject private var behavior = AutoScrollBehavior2()

    private var rowCount: Int {
        backendChips.count < 15 ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                        ChipRowView2(chips: chips, rowIndex: index, behavior: behavior)
                    }
                }
            }
            .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
                behavior.registerParent(scrollView)
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            behavior.start(repeatCount: repeatCount, chipSpacing: 10)
        }
        .onDisappear {
            behavior.stop()
        }
    }

    private func setupRows() {
        var baseRows: [[String]] = []

        if backendChips.count <= 3 {
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
                    Chip(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}

#Preview {
    ContentView2()
}
