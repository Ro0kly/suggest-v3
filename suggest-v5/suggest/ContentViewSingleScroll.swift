//
//  ContentViewSingleScroll.swift
//  suggest
//
//  Подход: DragGesture + CADisplayLink + .offset()
//  Нет UIScrollView, нет Introspect, нет синхронизации между scroll view.
//

import SwiftUI

// MARK: - Модель

struct ChipSS: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target (разрывает retain cycle CADisplayLink)

private class DisplayLinkTargetSS {
    weak var behavior: ChipSingleScrollBehavior?

    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - PreferenceKey для измерения ширины контента строки

private struct RowWidthKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Поведение скролла чипов

/// Управляет авто-скроллом, инерцией после drag, и бесконечным скроллом.
/// Вместо UIScrollView использует @Published offsets + DragGesture.
class ChipSingleScrollBehavior: ObservableObject {
    /// Смещения строк — двигают .offset() каждой строки
    @Published var rowOffsets: [CGFloat] = []

    /// Скорости авто-скролла на строку
    private var rowSpeeds: [CGFloat] = []
    /// Ширина одного набора чипов на строку (период)
    private var periods: [CGFloat] = []
    /// Кол-во повторов
    private var repeatCount = 0

    /// CADisplayLink для покадровой анимации
    private var displayLink: CADisplayLink?

    // -- Drag --
    /// Пользователь сейчас тянет
    private var isUserDragging = false
    /// Смещения строк в момент начала drag
    private var dragStartOffsets: [CGFloat] = []

    // -- Инерция --
    /// Скорость инерции (поинты/кадр)
    private var velocity: CGFloat = 0
    /// Коэффициент затухания
    private let deceleration: CGFloat = 0.97

    // -- Возобновление --
    private var resumeTask: Task<Void, Never>?

    // -- Фильтрация тапов --
    private var lastStopTime: CFTimeInterval = 0
    private let tapIgnoreWindow: CFTimeInterval = 0.3

    deinit { stop() }

    // MARK: - Публичный API

    /// Запускает поведение: создаёт массивы, задаёт скорости, стартует CADisplayLink.
    func start(rowCount: Int, repeatCount: Int) {
        self.repeatCount = repeatCount
        rowOffsets = Array(repeating: 0, count: rowCount)
        periods = Array(repeating: 0, count: rowCount)
        configureRowSpeeds(rowCount: rowCount)
        startDisplayLink()
    }

    /// Останавливает CADisplayLink и задачу возобновления.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    /// Устанавливает период для строки после измерения GeometryReader.
    /// Центрирует начальный offset.
    func setPeriod(forRow index: Int, totalWidth: CGFloat) {
        guard repeatCount > 0, index < periods.count else { return }
        let period = totalWidth / CGFloat(repeatCount)
        guard period > 0 else { return }
        periods[index] = period
        rowOffsets[index] = -period * CGFloat(repeatCount / 2)
    }

    // MARK: - Drag

    /// Палец двигается — применяем дельту ко всем строкам.
    func onDragChanged(translation: CGFloat) {
        if !isUserDragging {
            isUserDragging = true
            velocity = 0
            resumeTask?.cancel()
            resumeTask = nil
            dragStartOffsets = rowOffsets
        }
        var newOffsets = rowOffsets
        for i in newOffsets.indices {
            newOffsets[i] = dragStartOffsets[i] + translation
        }
        rowOffsets = newOffsets
    }

    /// Палец отпущен — вычисляем скорость инерции из предсказанной позиции.
    func onDragEnded(predicted: CGFloat, actual: CGFloat) {
        isUserDragging = false
        let remaining = predicted - actual
        velocity = remaining * (1 - deceleration)
        if abs(velocity) < 0.5 {
            velocity = 0
            scheduleResume()
        }
    }

    // MARK: - Тапы

    /// Останавливает и инерцию, и авто-скролл. Через 2 сек авто-скролл возобновится.
    func pauseOnTap() {
        velocity = 0
        lastStopTime = CACurrentMediaTime()
        scheduleResume()
    }

    /// Можно ли обработать тап как нажатие на чип.
    func shouldHandleTap() -> Bool {
        abs(velocity) <= 0.5 && CACurrentMediaTime() - lastStopTime > tapIgnoreWindow
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
        let target = DisplayLinkTargetSS()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTargetSS.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Каждый кадр: инерция или авто-скролл + оборачивание для бесконечности.
    func onFrame() {
        guard !isUserDragging else { return }
        guard periods.allSatisfy({ $0 > 0 }) else { return }

        var newOffsets = rowOffsets

        if abs(velocity) > 0.5 {
            // Инерция после drag
            for i in newOffsets.indices { newOffsets[i] += velocity }
            velocity *= deceleration
            if abs(velocity) <= 0.5 {
                velocity = 0
                lastStopTime = CACurrentMediaTime()
                scheduleResume()
            }
        } else if resumeTask == nil {
            // Авто-скролл
            for i in newOffsets.indices {
                newOffsets[i] += rowSpeeds[i]
            }
        }

        // Бесконечный скролл
        for i in newOffsets.indices {
            newOffsets[i] = wrapOffset(newOffsets[i], period: periods[i])
        }

        rowOffsets = newOffsets
    }

    // MARK: - Бесконечный скролл

    /// Если offset ушёл дальше 1 периода от центра — прыгаем обратно.
    private func wrapOffset(_ offset: CGFloat, period: CGFloat) -> CGFloat {
        guard period > 0 else { return offset }
        let center = -period * CGFloat(repeatCount / 2)
        var o = offset
        while o > center + period { o -= period }
        while o < center - period { o += period }
        return o
    }

    // MARK: - Возобновление

    /// Через 2 секунды обнуляет resumeTask → авто-скролл возобновляется.
    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.resumeTask = nil
        }
    }
}

// MARK: - Вью чипа

struct ChipViewSS: View {
    let chip: ChipSS

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

struct ChipRowViewSS: View {
    let chips: [ChipSS]
    let rowIndex: Int
    let offset: CGFloat
    let onTap: (ChipSS) -> Void

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipViewSS(chip: chip)
                        .onTapGesture { onTap(chip) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowWidthKey.self,
                        value: [rowIndex: geo.size.width]
                    )
                }
            )
            .offset(x: offset)
        }
        .frame(height: 52)
        .clipped()
    }
}

// MARK: - Главная вью

struct ContentViewSingleScroll: View {
    private let repeatCount = 5

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

    @State private var rows: [[ChipSS]] = []
    @StateObject private var behavior = ChipSingleScrollBehavior()

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
                    ChipRowViewSS(
                        chips: chips,
                        rowIndex: index,
                        offset: index < behavior.rowOffsets.count ? behavior.rowOffsets[index] : 0
                    ) { chip in
                        behavior.pauseOnTap()
                        guard behavior.shouldHandleTap() else { return }
                        print("Tapped: \(chip.text)")
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    behavior.pauseOnTap()
                }
            )
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { behavior.onDragChanged(translation: $0.translation.width) }
                    .onEnded {
                        behavior.onDragEnded(
                            predicted: $0.predictedEndTranslation.width,
                            actual: $0.translation.width
                        )
                    }
            )
            .onPreferenceChange(RowWidthKey.self) { widths in
                for (index, width) in widths {
                    behavior.setPeriod(forRow: index, totalWidth: width)
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
                    ChipSS(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}
