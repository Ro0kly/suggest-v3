//
//  ContentView4point3.swift
//  suggest
//
//  Created by Rookly on 15.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

@propertyWrapper

public struct NonEquatable<Value: Sendable>: Equatable, Sendable {
    
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
    
    public var wrappedValue: Value
    public static func == (lhs: NonEquatable<Value>, rhs: NonEquatable<Value>) -> Bool {
        true
    }
}

// MARK: - Модель

/// Модель чипа-подсказки. Известна и разработчику, и компоненту.
/// Разработчик заполняет text + onTap, компонент использует их при создании бесконечного скролла.
struct Chip4p3: Identifiable {
    let id: String
    let text: String
    
    @NonEquatable
    var onTap: () -> Void

    init(_ text: String, index: Int, onTap: @escaping () -> Void) {
        self.id = "\(text)-\(index)"
        self.text = text
        self.onTap = onTap
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

    /// true после тап-остановки скролла. shouldHandleTap() читает и сбрасывает флаг,
    /// чтобы тот же тап не засчитался как выбор чипа.
    private var tapStopped = false

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
        scrollView.layoutIfNeeded()
        scrollView.contentOffset.x = (scrollView.contentSize.width - scrollView.bounds.width) / 2
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

    /// Проверяет, можно ли обработать тап по чипу. Если тап был остановкой скролла —
    /// возвращает false и сбрасывает флаг.
    func shouldHandleTap() -> Bool {
        defer { tapStopped = false }
        return !tapStopped
    }

    // MARK: - Per-frame

    /// Покадровый тик от CADisplayLink.
    /// 1. Репозиционирование (поддержание бесконечного скролла)
    /// 2. Авто-скролл (только если юзер не взаимодействует)
    func onFrame() {
        repositionForInfiniteScroll()

        guard !isUserScrolling else { return }
        advanceAutoScroll()
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

    /// Дельта-синхронизация с учётом скоростей: каждая строка получает дельту
    /// пропорционально отношению своей скорости к скорости активной строки.
    /// Пример: юзер тянет Row 0 (speed 0.5) на 100px → Row 1 (speed 0.8) сдвинется на 160px.
    /// Clamping [0, maxX] предотвращает выход за границы контента.
    private func syncOtherRows(to scrollView: UIScrollView) {
        guard let originX = allDragOrigins[scrollView.tag] else { return }
        let delta = scrollView.contentOffset.x - originX
        let activeSpeed = abs(rowSpeeds[scrollView.tag] ?? 1)

        for (index, sv) in scrollViews where sv !== scrollView {
            guard let startX = allDragOrigins[index] else { continue }
            let ratio = activeSpeed > 0 ? abs(rowSpeeds[index] ?? 1) / activeSpeed : 1
            let newX = startX + delta * ratio
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

    /// Юзер отпустил палец. Если decelerate = false (отпустил без инерции) -
    /// сбрасываем drag origins и планируем возобновление авто-скролла.
    /// Если decelerate = true - ждём scrollViewDidEndDecelerating.
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
            tapStopped = true
            stopRows()
            allDragOrigins = [:]
            scheduleAutoScrollResume()
        }
    }
}

// MARK: - Вью чипа

/// Визуальное представление одного чипа. Не знает о behavior — onTap уже содержит всю логику.
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
            .padding(6)
            .onTapGesture { chip.onTap() }
    }
}

// MARK: - Вью строки чипов

/// Одна горизонтальная строка чипов. ScrollView для нативной физики скролла,
/// Introspect для доступа к UIScrollView (регистрация в behavior).
struct ChipRowView4p3: View {
    let chips: [Chip4p3]
    let rowIndex: Int
    let behavior: ChipInfiniteScrollBehavior

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(chips) { chip in
                    ChipView4p3(chip: chip)
                }
            }
        }
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

    /// Чипы от разработчика. Передаются извне — point3 ничего не знает об их бизнес-логике.
    let chips: [Chip4p3]

    /// Финальные строки чипов (после разбиения, padding и repeatCount-повторения).
    @State private var rows: [[Chip4p3]] = []

    /// Координатор поведения. @StateObject — создаётся один раз, живёт пока живёт вью.
    @StateObject private var behavior = ChipInfiniteScrollBehavior()

    /// 2 строки для < 15 чипов, 3 строки для >= 15.
    private var rowCount: Int {
        chips.count < 15 ? 2 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, chips in
                    ChipRowView4p3(chips: chips, rowIndex: index, behavior: behavior)
                }
            }

            Spacer()
        }
        .padding(.top)
        .background(Color.white.ignoresSafeArea())
        .onAppear {
            setupRows()
            behavior.start(rowCount: rowCount, repeatCount: repeatCount, chipSpacing: 0)
        }
        .onDisappear {
            behavior.stop()
        }
    }

    private func setupRows() {
        // Разбиваем чипы на строки → каждую строку превращаем в бесконечную ленту
        rows = splitIntoRows().map { makeInfiniteRow(from: $0) }
    }

    private func splitIntoRows() -> [[Chip4p3]] {
        // Чипов на строку (округляем вверх чтобы последняя строка была короче, а не пустой)
        // Пример: 10 чипов / 2 строки = 5
        let perRow = Int(ceil(Double(chips.count) / Double(rowCount)))

        // Создаём rowCount строк (2 или 3)
        return (0..<rowCount).map { i in
            // Начало блока для строки i. Строка 0 → 0, строка 1 → 5
            let start = i * perRow

            // Если чипов меньше чем строк (1 чип, 2 строки) — строка 1 начиналась бы
            // за пределами массива. Отдаём ей все чипы целиком как fallback
            guard start < chips.count else { return chips }

            // Вырезаем блок [start, start+perRow). min защищает от выхода за конец в последней строке
            return Array(chips[start..<min(start + perRow, chips.count)])
        }
    }

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Задача: из source [A, B, C, D, E] сделать бесконечную ленту.      │
    // │                                                                     │
    // │ Шаг 1. Определить ширину одного ПЕРИОДА.                           │
    // │   Период должен быть шире 2× экрана, иначе юзер доскроллит до края │
    // │   (repositioning не прыгает пока палец на экране).                  │
    // │   Если source короткий — повторяем его несколько раз (cyclesForWidth).│
    // │                                                                     │
    // │   source = [A,B,C,D,E], cyclesForWidth = 4:                        │
    // │   1 период = [A,B,C,D,E,A,B,C,D,E,A,B,C,D,E,A,B,C,D,E]  (20 шт) │
    // │                                                                     │
    // │ Шаг 2. Повторить период × repeatCount (3).                         │
    // │   3 одинаковых периода — repositioning прыгает на ±1 период,        │
    // │   и это незаметно (те же чипы в том же порядке).                    │
    // │                                                                     │
    // │   |--- период 1 ---|--- период 2 ---|--- период 3 ---|             │
    // │   [A,B,C,D,E,...]  [A,B,C,D,E,...]  [A,B,C,D,E,...]              │
    // │                     ↑ viewport                                      │
    // │   Когда viewport уходит к краю → прыжок на 1 период назад/вперёд. │
    // │                                                                     │
    // │ Шаг 3. Заполнить массив через i % source.count.                    │
    // │   i: 0  1  2  3  4  5  6  7  8  9  10 ...                         │
    // │   %: A  B  C  D  E  A  B  C  D  E  A  ...                         │
    // │   Один оператор % заменяет вложенные циклы.                        │
    // │                                                                     │
    // │ Шаг 4. Обернуть onTap каждого чипа в shouldHandleTap.              │
    // │   Разработчик передал свой onTap → мы добавляем проверку            │
    // │   «не был ли этот тап остановкой скролла».                         │
    // └─────────────────────────────────────────────────────────────────────┘
    private func makeInfiniteRow(from source: [Chip4p3]) -> [Chip4p3] {
        let behavior = self.behavior

        // Шаг 1: ширина периода
        let minChipWidth: CGFloat = 47 // мин. ширина чипа (35) + padding (12)
        let minBaseChips = Int(ceil(2 * UIScreen.main.bounds.width / minChipWidth))
        let cyclesForWidth = max(1, Int(ceil(Double(minBaseChips) / Double(source.count))))

        // Шаг 2: × repeatCount копий
        let totalChips = cyclesForWidth * source.count * repeatCount

        // Шаг 3 + 4: заполняем через модуль, оборачиваем onTap
        return (0..<totalChips).map { i in
            let original = source[i % source.count]
            return Chip4p3(original.text, index: i) { [weak behavior] in
                guard let behavior, behavior.shouldHandleTap() else { return }
                original.onTap()
            }
        }
    }
}
