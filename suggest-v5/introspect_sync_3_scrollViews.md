# Chip Suggestions Scroll — Обоснование архитектуры

## Требования

- 2-3 горизонтальных строки чипов-подсказок
- Авто-скролл на **разных скоростях** для каждой строки
- Юзер может скроллить руками (все строки синхронизированы)
- Бесконечный скролл
- Тап по чипу = выбор, тап во время скролла = остановка
- Минимальная цель: iOS 15, SwiftUI

## Выбранный подход

**Несколько UIScrollView + SwiftUI Introspect**

Каждая строка — SwiftUI `ScrollView`, через Introspect получаем `UIScrollView`.
Один координатор (`ChipInfiniteScrollBehavior`) управляет всеми строками.

### Почему именно так

- `UIScrollView.contentOffset` изменяется через Core Animation напрямую — **0% нагрузки на SwiftUI** при авто-скролле (view tree не перестраивается)
- Нативная физика скролла (инерция, deceleration) без имитации
- SwiftUI остаётся для декларативной раскладки чипов (`HStack`, стили, тапы)

### Метрики (iPhone, release build)

| Метрика | UIScrollView (point3) | `.offset()` через SwiftUI |
|---------|-----------------------|---------------------------|
| CPU при авто-скролле | ~22% | до 90% |
| Память | базовая | ×2 |
| Energy Impact | Low | High |
| Плавность | 60/120 FPS стабильно | дёрганый скролл |

## Исследованные альтернативы

### 1. Один ScrollView + `.offset()` на каждой строке

Один UIScrollView для юзер-скролла (нативная физика). Внутри — VStack из 3 HStack, каждый с `.offset(x:)` для авто-скролла на своей скорости.

**Проблема:** `.offset()` обновляется через `@Published` 60-120 раз/сек → SwiftUI перестраивает view tree каждый кадр. CPU до 90%, дёрганый скролл, удвоенная память, Energy Impact: High.

### 2. Чистый SwiftUI: DragGesture + `.offset()`

Полностью без UIKit. `DragGesture` для юзер-скролла, `.offset()` для авто-скролла, ручная инерция (`velocity *= 0.97`).

**Проблемы:**
- Та же проблема с `.offset()` + перестроение view tree
- Нет нативной инерции — ручная реализация ощущается иначе
- Конфликт `DragGesture` с `onTapGesture` на чипах

### 3. Один ScrollView для всех строк + `.offset()` для разницы скоростей

Все 3 строки внутри одного горизонтального ScrollView. Юзер-скролл — нативный (все строки двигаются вместе). Разница скоростей авто-скролла — через `.offset()` на каждом HStack.

**Проблема:** ScrollView двигает все строки одинаково — это нормально для юзер-скролла. Но для авто-скролла на разных скоростях нужен `.offset()` через `@Published` на каждый кадр → та же проблема с перестроением view tree, CPU до 90%, дёрганый скролл.

### 4. UIViewRepresentable вместо Introspect

Каждая строка — UIViewRepresentable с UIScrollView. Чипы создаются в UIKit (UILabel + ручной layout) или через UIHostingController.

**Проблема:** логика поведения (~250 строк) идентична текущему подходу. Но теряем декларативную раскладку чипов — приходится вручную считать фреймы в UIKit. Больше кода, не меньше.

## Ключевой вывод

Задача «разные скорости авто-скролла по строкам» **требует** отдельный UIScrollView на каждую строку. Любой подход с одним scroll view или с `.offset()` через SwiftUI state либо не поддерживает разные скорости, либо неприемлемо тяжёл для рендера.

## Ключевые технические решения

| Решение | Причина |
|---------|---------|
| Несколько UIScrollView, а не один | Разные скорости авто-скролла на строку |
| SwiftUI Introspect, а не UIViewRepresentable | Сохраняем декларативную раскладку чипов |
| CADisplayLink, а не Timer | Синхронизация с частотой экрана (60-120 FPS) |
| Дельта-синхронизация при юзер-скролле | Сохраняет разницу позиций между строками, без прыжков |
| DisplayLinkTarget (weak proxy) | CADisplayLink сильно удерживает target → retain cycle |
| `[weak self]` в Task | Предотвращает retain cycle в `scheduleResume` |
| Репозиционирование по периоду | Бесконечный скролл: прыжок на 1 период незаметен т.к. контент повторяется |
| HStack, а не LazyHStack | LazyHStack не успевает загрузить вьюхи в точке приземления после прыжка |
| `lastTapStopTime` вместо bool-флага | Временное окно (0.3 сек) надёжнее чем однократный флаг |

## Архитектура

```
ContentView4point3
├── ChipInfiniteScrollBehavior (NSObject, UIScrollViewDelegate, ObservableObject)
│   ├── register() — регистрация UIScrollView через Introspect
│   ├── start() / stop() — управление CADisplayLink
│   ├── onFrame() — покадровый тик
│   │   ├── centerRowsIfNeeded() — центрирование при старте
│   │   ├── repositionForInfiniteScroll() — прыжок на ±1 период
│   │   └── advanceAutoScroll() — сдвиг каждой строки на свою скорость
│   ├── UIScrollViewDelegate
│   │   ├── scrollViewWillBeginDragging → пауза авто-скролла
│   │   ├── scrollViewDidScroll → дельта-синхронизация строк
│   │   ├── scrollViewDidEndDragging → планирование возобновления
│   │   └── scrollViewDidEndDecelerating → планирование возобновления
│   └── Хелперы
│       ├── syncOtherRows(to:) — дельта-синхронизация
│       ├── stopAllRows() — остановка тапом
│       └── scheduleAutoScrollResume() — возобновление через 2 сек
├── ChipRowView — ScrollView + HStack + Introspect
├── ChipView — визуал чипа
└── DisplayLinkTarget — weak proxy для CADisplayLink
```
