//
//  ContentViewSingleScrollNoDragGesture.swift
//  suggest
//
//  Гибрид: один ScrollView (Introspect) для юзер-скролла (нативная физика),
//  внутри 3 HStack с .offset() для авто-скролла на разных скоростях.
//  Нет DragGesture, нет синхронизации между scroll view.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Модель

struct ChipND: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target

private class DisplayLinkTargetND {
    weak var behavior: ChipHybridBehavior?

    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - PreferenceKey для измерения ширины строки

private struct RowWidthKeyND: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Поведение гибридного скролла

/// Один UIScrollView для юзер-скролла + .offset() для авто-скролла каждой строки.
class ChipHybridBehavior: NSObject, UIScrollViewDelegate, ObservableObject {
    /// Дополнительные смещения каждой строки для авто-скролла (двигают .offset())
    @Published var autoOffsets: [CGFloat] = []

    /// Ссылка на единственный UIScrollView
    private weak var scrollView: UIScrollView?

    /// Скорости авто-скролла на строку
    private var rowSpeeds: [CGFloat] = []
    /// Ширина одного набора чипов на строку (период)
    private var periods: [CGFloat] = []
    /// Кол-во повторов
    private var repeatCount = 0

    /// CADisplayLink для покадровой анимации
    private var displayLink: CADisplayLink?

    /// Пользователь взаимодействует со скроллом
    private var isUserScrolling = false
    /// ScrollView замедлялся (инерция) когда юзер тапнул
    private var wasDecelerating = false
    /// Нужно отцентрировать ScrollView при первом появлении
    private var needsCentering = true

    /// Задача отложенного возобновления
    private var resumeTask: Task<Void, Never>?

    /// Время последней остановки (для фильтрации ложных тапов по чипам)
    private var lastStopTime: CFTimeInterval = 0
    private let tapIgnoreWindow: CFTimeInterval = 0.3

    deinit { stop() }

    // MARK: - Публичный API

    /// Регистрирует UIScrollView и добавляет UITapGestureRecognizer для паузы.
    func register(_ scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        scrollView.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)
    }

    /// Запускает авто-скролл.
    func start(rowCount: Int, repeatCount: Int) {
        self.repeatCount = repeatCount
        autoOffsets = Array(repeating: 0, count: rowCount)
        periods = Array(repeating: 0, count: rowCount)
        configureRowSpeeds(rowCount: rowCount)
        startDisplayLink()
    }

    /// Останавливает всё.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    /// Устанавливает период для строки после измерения.
    func setPeriod(forRow index: Int, width: CGFloat) {
        guard repeatCount > 0, index < periods.count else { return }
        let period = width / CGFloat(repeatCount)
        guard period > 0 else { return }
        periods[index] = period
    }

    /// Можно ли обработать тап как нажатие на чип.
    func shouldHandleTap() -> Bool {
        !wasDecelerating && CACurrentMediaTime() - lastStopTime > tapIgnoreWindow
    }

    // MARK: - Тап (пауза авто-скролла)

    /// UITapGestureRecognizer — ловит тапы по всему ScrollView.
    /// Если скролл замедлялся — блокирует ложный тап по чипу.
    @objc func handleTap() {
        if wasDecelerating {
            lastStopTime = CACurrentMediaTime()
            wasDecelerating = false
        }
        isUserScrolling = false
        scheduleResume()
    }

    // MARK: - Конфигурация

    private func configureRowSpeeds(rowCount: Int) {
        if rowCount == 2 {
            rowSpeeds = [-0.5, -0.8]
        } else {
            rowSpeeds = [-0.4, -0.6, -0.9]
        }
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTargetND()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTargetND.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Каждый кадр: центрируем (один раз), затем двигаем авто-скролл + оборачиваем.
    func onFrame() {
        centerScrollViewIfNeeded()

        guard !isUserScrolling else { return }
        guard resumeTask == nil else { return }
        guard periods.allSatisfy({ $0 > 0 }) else { return }

        var newOffsets = autoOffsets
        for i in newOffsets.indices {
            newOffsets[i] += rowSpeeds[i]
            newOffsets[i] = wrapAutoOffset(newOffsets[i], period: periods[i])
        }
        autoOffsets = newOffsets
    }

    // MARK: - Центрирование

    /// При первом появлении ставит ScrollView в центр контента.
    private func centerScrollViewIfNeeded() {
        guard needsCentering, let sv = scrollView else { return }
        guard sv.contentSize.width > sv.bounds.width else { return }
        sv.contentOffset.x = (sv.contentSize.width - sv.bounds.width) / 2
        needsCentering = false
    }

    // MARK: - Бесконечный авто-скролл

    /// Оборачивает autoOffset в пределах одного периода.
    private func wrapAutoOffset(_ offset: CGFloat, period: CGFloat) -> CGFloat {
        guard period > 0 else { return offset }
        var o = offset
        while o < -period { o += period }
        while o > 0 { o -= period }
        return o
    }

    // MARK: - Возобновление

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.resumeTask = nil
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
        wasDecelerating = false
        resumeTask?.cancel()
        resumeTask = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        wasDecelerating = decelerate
        if !decelerate {
            isUserScrolling = false
            scheduleResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        wasDecelerating = false
        isUserScrolling = false
        scheduleResume()
    }
}

// MARK: - Вью чипа

struct ChipViewND: View {
    let chip: ChipND

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

// MARK: - Вью строки чипов

struct ChipRowND: View {
    let chips: [ChipND]
    let rowIndex: Int
    let autoOffset: CGFloat
    let onTap: (ChipND) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(chips) { chip in
                ChipViewND(chip: chip)
                    .onTapGesture { onTap(chip) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowWidthKeyND.self,
                    value: [rowIndex: geo.size.width]
                )
            }
        )
        .offset(x: autoOffset)
        .frame(height: 52)
    }
}

// MARK: - Главная вью

struct ContentViewSingleScrollNoDragGesture: View {
    private let repeatCount = 30

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
        "Loan calculator",
        "Savings goal",
        "Credit score",
        "Direct debit",
        "Standing order",
        "Travel insurance",
        "Cashback offers",
        "Overdraft limit",
        "Mortgage rates",
        "Investment plans",
        "Report fraud",
        "Close account"
    ]

    @State private var rows: [[ChipND]] = []
    @StateObject private var behavior = ChipHybridBehavior()

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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                        ChipRowND(
                            chips: chips,
                            rowIndex: index,
                            autoOffset: index < behavior.autoOffsets.count ? behavior.autoOffsets[index] : 0
                        ) { chip in
                            guard behavior.shouldHandleTap() else { return }
                            print("Tapped: \(chip.text)")
                        }
                    }
                }
            }
            .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
                behavior.register(scrollView)
            }
            .onPreferenceChange(RowWidthKeyND.self) { widths in
                for (index, width) in widths {
                    behavior.setPeriod(forRow: index, width: width)
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            behavior.start(rowCount: rowCount, repeatCount: repeatCount)
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
                    ChipND(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}
