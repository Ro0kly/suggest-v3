//
//  ContentView4point3.swift
//  suggest
//
//  Created by Rookly on 15.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Модель

/// Модель чипа-подсказки. `id` формируется из текста и порядкового индекса,
/// чтобы одинаковый текст в разных позициях оставался уникальным для ForEach.
struct Chip4p3: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - DisplayLink Target

/// Weak-proxy для CADisplayLink. CADisplayLink сильно удерживает свой target —
/// если передать туда сам behavior напрямую, образуется retain cycle
/// (behavior → displayLink → behavior). Proxy держит weak-ссылку, разрывая цикл.
private class DisplayLinkTarget4p3 {
    weak var behavior: ChipInfiniteScrollBehavior?

    /// Вызывается CADisplayLink каждый кадр (60–120 раз/сек).
    @objc func tick() {
        behavior?.onFrame()
    }
}

// MARK: - Поведение бесконечного скролла чипов

/// Координирует авто-скролл, синхронизацию строк, бесконечный скролл
/// и обработку пользовательских жестов для всех строк чипов.
/// ObservableObject без @Published — намеренно: нужен для @StateObject,
/// но SwiftUI state system не используется (всё через Core Animation).
class ChipInfiniteScrollBehavior: NSObject, UIScrollViewDelegate, ObservableObject {

    /// Зарегистрированные scroll view по индексу строки. Заполняется через `register()`.
    private var scrollViews: [Int: UIScrollView] = [:]

    /// Флаг-замок: пока true, `scrollViewDidScroll` игнорирует вызовы.
    /// Предотвращает рекурсию: мы меняем offset программно → UIKit зовёт delegate → мы снова меняем.
    private var isSyncing = false

    /// Начальные позиции X всех строк в момент начала drag.
    /// Используется для дельта-синхронизации: delta = текущий offset − origin.
    /// Пустой словарь = нет активного drag/deceleration (служит как флаг).
    private var allDragOrigins: [Int: CGFloat] = [:]

    /// Момент последней остановки скролла тапом. Используется в `shouldHandleTap()`
    /// чтобы не засчитывать тап-остановку как тап по чипу.
    private var lastTapStopTime: CFTimeInterval = 0

    /// Временное окно (сек) после тап-остановки, в течение которого тапы по чипам игнорируются.
    private let tapIgnoreWindow: CFTimeInterval = 0.3

    /// Таймер, синхронизированный с частотой экрана (60–120 FPS). Вызывает `onFrame()` каждый кадр.
    private var displayLink: CADisplayLink?

    /// Скорость авто-скролла для каждой строки (px/кадр). Отрицательное = влево.
    private var rowSpeeds: [Int: CGFloat] = [:]

    /// true пока юзер взаимодействует (drag/deceleration/пауза после отпускания).
    /// Пока true, авто-скролл приостановлен.
    private var isUserScrolling = false

    /// Задача отложенного возобновления авто-скролла (2 сек после окончания взаимодействия).
    /// Cancellable: если юзер снова начнёт скроллить, задача отменяется.
    private var resumeTask: Task<Void, Never>?

    /// true до первого успешного центрирования. После — false навсегда.
    /// Центрирование ждёт пока SwiftUI завершит layout (contentSize > boundsWidth).
    private var needsCentering = true

    /// Сколько раз base row повторяется в HStack. Нужен для расчёта периода при репозиционировании.
    private var repeatCount = 0

    /// Расстояние между чипами в HStack. Нужен для точного расчёта периода.
    private var chipSpacing: CGFloat = 0

    deinit { stop() }

    // MARK: - Публичный API

    /// Регистрирует UIScrollView для управления. Вызывается из Introspect-колбэка каждой строки.
    /// guard !== предотвращает повторную регистрацию (Introspect может вызваться несколько раз).
    /// tag хранит индекс строки — используется в delegate-методах для идентификации источника.
    func register(_ scrollView: UIScrollView, rowIndex: Int) {
        guard scrollViews[rowIndex] !== scrollView else { return }
        scrollViews[rowIndex] = scrollView
        scrollView.delegate = self
        scrollView.tag = rowIndex
    }

    /// Запускает авто-скролл. Настраивает скорости строк и создаёт CADisplayLink.
    /// Режим `.common` позволяет display link работать даже во время tracking (юзер-скролла) —
    /// мы сами решаем когда паузить через `isUserScrolling`.
    /// guard displayLink == nil предотвращает повторное создание при повторном .onAppear.
    func start(rowCount: Int, repeatCount: Int, chipSpacing: CGFloat) {
        self.repeatCount = repeatCount
        self.chipSpacing = chipSpacing
        rowSpeeds = rowCount == 2
            ? [0: -0.5, 1: -0.8]
            : [0: -0.4, 1: -0.6, 2: -0.9]

        guard displayLink == nil else { return }
        let target = DisplayLinkTarget4p3()
        target.behavior = self
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget4p3.tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Останавливает всё: уничтожает CADisplayLink и отменяет задачу возобновления.
    /// Вызывается из .onDisappear и deinit.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTask?.cancel()
    }

    /// Проверяет, можно ли обработать тап по чипу. Возвращает false в течение 0.3 сек
    /// после тап-остановки скролла, чтобы тап-остановка не засчитывалась как выбор чипа.
    func shouldHandleTap() -> Bool {
        CACurrentMediaTime() - lastTapStopTime > tapIgnoreWindow
    }

    // MARK: - Per-frame

    /// Покадровый тик от CADisplayLink. Порядок вызовов важен:
    /// 1. Центрирование (один раз при старте, потом no-op)
    /// 2. Репозиционирование (поддержание бесконечного скролла)
    /// 3. Авто-скролл (только если юзер не взаимодействует)
    func onFrame() {
        centerRowsIfNeeded()
        repositionForInfiniteScroll()

        guard !isUserScrolling else { return }
        advanceAutoScroll()
    }

    /// Один раз при старте ставит все строки в центр контента.
    /// Ждёт пока SwiftUI завершит layout (contentSize > boundsWidth у всех scroll view).
    /// После первого срабатывания needsCentering = false — все последующие вызовы
    /// выходят на первом guard (одна проверка Bool, по сути бесплатно).
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

    /// Бесконечный скролл через репозиционирование. Контент повторяется repeatCount раз,
    /// поэтому прыжок на ±1 период визуально незаметен (те же чипы в том же порядке).
    /// Пропускает scroll view с isTracking = true (юзер держит палец — прыжок ощущался бы).
    /// allDragOrigins корректируется вместе с offset, чтобы дельта-синхронизация не сломалась.
    private func repositionForInfiniteScroll() {
        isSyncing = true
        for (index, sv) in scrollViews {
            guard !sv.isTracking else { continue }

            /// Период = ширина одного повторения base row (включая spacing после последнего чипа).
            let period = (sv.contentSize.width + chipSpacing) / CGFloat(repeatCount)
            /// Максимальный offset (правый край контента совпадает с правым краем scroll view).
            let maxOffset = sv.contentSize.width - sv.bounds.width
            guard period > 0, maxOffset > period else { continue }

            /// Пороги: period/2 от каждого края. Когда offset выходит за порог — прыжок.
            var adjustment: CGFloat = 0
            if sv.contentOffset.x > maxOffset - period / 2 {
                adjustment = -period
            } else if sv.contentOffset.x < period / 2 {
                adjustment = period
            }

            if adjustment != 0 {
                sv.contentOffset.x += adjustment
                allDragOrigins[index]? += adjustment
            }
        }
        isSyncing = false
    }

    /// Сдвигает каждую строку на её скорость (px/кадр). Обёрнут в isSyncing
    /// чтобы scrollViewDidScroll не реагировал на программное изменение offset.
    private func advanceAutoScroll() {
        isSyncing = true
        for (index, sv) in scrollViews {
            guard let speed = rowSpeeds[index] else { continue }
            sv.contentOffset.x -= speed
        }
        isSyncing = false
    }

    // MARK: - Хелперы

    /// Планирует возобновление авто-скролла через 2 секунды после окончания взаимодействия.
    /// cancel() предыдущей задачи сбрасывает таймер (если юзер скроллит несколько раз подряд).
    /// [weak self] разрывает retain cycle: Task захватывает self → self держит resumeTask → цикл.
    /// Дополнительная проверка isDragging/isDecelerating на случай если юзер начал новый жест
    /// в промежутке между планированием и срабатыванием.
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

    /// Останавливает инерцию (deceleration) scroll view. setContentOffset на текущую позицию
    /// с animated: false мгновенно прекращает инерцию, не сдвигая контент.
    /// except: исключает указанный scroll view (при начале drag — не трогать тот, что юзер тянет).
    /// nil = остановить все (при тап-остановке).
    private func stopRows(except scrollView: UIScrollView? = nil) {
        isSyncing = true
        for (_, sv) in scrollViews where sv !== scrollView {
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
        isSyncing = false
    }

    /// Дельта-синхронизация: двигает все строки кроме активной на ту же дельту.
    /// delta = текущий offset активной строки − её начальная позиция (из allDragOrigins).
    /// Каждая другая строка: newOffset = своя начальная позиция + delta.
    /// Clamping [0, maxX] предотвращает выход за границы контента.
    /// Результат: все строки движутся синхронно, сохраняя свои начальные разницы позиций.
    private func syncOtherRows(to scrollView: UIScrollView) {
        guard let originX = allDragOrigins[scrollView.tag] else { return }
        let delta = scrollView.contentOffset.x - originX

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = allDragOrigins[index] else { continue }
            let newX = startX + delta
            let maxX = sv.contentSize.width - sv.bounds.width
            if newX >= 0 && newX <= maxX {
                sv.contentOffset.x = newX
            }
        }
    }

    /// Проверяет, трогает ли юзер какую-либо другую строку (кроме переданной).
    /// Используется в scrollViewDidScroll для обнаружения тап-остановки по другой строке.
    private func anotherRowIsTracking(except scrollView: UIScrollView) -> Bool {
        scrollViews.values.contains { $0 !== scrollView && $0.isTracking }
    }

    // MARK: - UIScrollViewDelegate

    /// Юзер начал тянуть строку.
    /// 1. Отменяем таймер возобновления (юзер снова взаимодействует).
    /// 2. Паузим авто-скролл.
    /// 3. Останавливаем инерцию всех ДРУГИХ строк (иначе decelerating строка будет
    ///    «бороться» с syncOtherRows за свою позицию).
    /// 4. Снимаем snapshot позиций ВСЕХ строк — базис для дельта-синхронизации.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resumeTask?.cancel()
        isUserScrolling = true
        stopRows(except: scrollView)
        allDragOrigins = scrollViews.mapValues { $0.contentOffset.x }
    }

    /// Юзер отпустил палец. Если decelerate = false (отпустил без инерции) —
    /// сбрасываем drag origins и планируем возобновление авто-скролла.
    /// Если decelerate = true — ждём scrollViewDidEndDecelerating.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            allDragOrigins = [:]
            scheduleAutoScrollResume()
        }
    }

    /// Инерция (deceleration) полностью остановилась.
    /// Сбрасываем drag origins и планируем возобновление авто-скролла.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        allDragOrigins = [:]
        scheduleAutoScrollResume()
    }

    /// Вызывается UIKit при ЛЮБОМ изменении offset (drag, deceleration, программное).
    /// guard !isSyncing — игнорируем вызовы от наших собственных изменений offset.
    /// guard !allDragOrigins.isEmpty — реагируем только если есть активный drag/deceleration.
    ///
    /// Основная логика:
    /// 1. Синхронизируем остальные строки с той, чей offset изменился.
    /// 2. Проверяем тап-остановку: если юзер трогает ДРУГУЮ строку (isTracking) —
    ///    значит он тапнул чтобы остановить. Останавливаем всё, запоминаем время тапа.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSyncing, !allDragOrigins.isEmpty else { return }

        isSyncing = true
        syncOtherRows(to: scrollView)
        isSyncing = false

        if anotherRowIsTracking(except: scrollView) {
            lastTapStopTime = CACurrentMediaTime()
            stopRows()
            allDragOrigins = [:]
            scheduleAutoScrollResume()
        }
    }
}

// MARK: - Вью чипа

/// Визуальное представление одного чипа. Stateless — только отображение.
struct ChipView4p3: View {
    let chip: Chip4p3

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

/// Одна горизонтальная строка чипов. ScrollView для нативной физики скролла,
/// Introspect для доступа к UIScrollView (регистрация в behavior).
/// onTap с guard shouldHandleTap() — защита от ложных тапов при тап-остановке.
struct ChipRowView4p3: View {
    let chips: [Chip4p3]
    let rowIndex: Int
    let behavior: ChipInfiniteScrollBehavior
    let onTap: (Chip4p3) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(chips) { chip in
                    ChipView4p3(chip: chip)
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

// MARK: - Главная вью

struct ContentView4point3: View {
    /// Сколько раз base row повторяется для создания бесконечного скролла.
    /// 3 повторения достаточно для репозиционирования (прыжок на ±1 период незаметен).
    private let repeatCount = 3

//    private let backendChips = [
//        "Check balance",
//        "Recent transactions",
//        "Transfer money",
//        "Pay bills",
//        "Card limits",
//        "Open account",
//        "Exchange rates",
//        "Find ATM",
//        "Block card",
//        "Loan calculator"
//    ]

    private let backendChips = (1...21).map { String($0) }

    /// Финальные строки чипов (после разбиения, padding и repeatCount-повторения).
    @State private var rows: [[Chip4p3]] = []

    /// Координатор поведения. @StateObject — создаётся один раз, живёт пока живёт вью.
    @StateObject private var behavior = ChipInfiniteScrollBehavior()

    /// 2 строки для < 15 чипов, 3 строки для >= 15.
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
                    ChipRowView4p3(chips: chips, rowIndex: index, behavior: behavior) { chip in
                        print("Tapped: \(chip.text)")
                    }
                }
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            setupRows()
            behavior.start(rowCount: rowCount, repeatCount: repeatCount, chipSpacing: 10)
        }
        .onDisappear {
            behavior.stop()
        }
    }

    /// Разбивает backendChips на строки, дополняет короткие строки для широких экранов,
    /// и повторяет каждую строку repeatCount раз для бесконечного скролла.
    private func setupRows() {
        // 1. Разбиение на строки.
        // <= 3 чипов: каждая строка получает все чипы (иначе строки были бы слишком короткими).
        // > 3 чипов: последовательное распределение (1–5 → Row 0, 6–10 → Row 1).
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

        // Во время drag (isTracking = true) repositionForInfiniteScroll пропускает
        // scroll view — пользователь может доскроллить до края контента пальцем.
        // Чтобы этого не случилось, period/2 должен превышать ширину экрана:
        // тогда даже из худшей позиции после репозиционирования (period/2 от края)
        // полный свайп через весь экран не достигнет границы контента.
        // period ≈ baseChips × (minChipWidth + spacing), отсюда:
        // baseChips > 2 × screenWidth / (minChipWidth + spacing).
        let screenWidth = UIScreen.main.bounds.width
        let minChipWidth: CGFloat = 35
        let chipSpacing: CGFloat = 10
        let minBaseChips = Int(ceil(2 * screenWidth / (minChipWidth + chipSpacing)))

        // 2. Padding коротких строк дубликатами.
        baseRows = baseRows.map { row in
            guard row.count < minBaseChips else { return row }
            /// Сколько раз продублировать строку чтобы набрать minBaseChips чипов.
            let times = Int(ceil(Double(minBaseChips) / Double(row.count)))
            return (0..<times).flatMap { _ in row }
        }

        // 3. Повторение каждой base row repeatCount раз.
        // Индекс чипа = repeatIndex * baseCount + chipIndex — гарантирует уникальные id
        // даже при дублированных текстах.
        rows = baseRows.map { baseChips in
            (0..<repeatCount).flatMap { repeatIndex in
                baseChips.enumerated().map { chipIndex, text in
                    Chip4p3(text, index: repeatIndex * baseChips.count + chipIndex)
                }
            }
        }
    }
}
