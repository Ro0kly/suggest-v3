//
//  ContentView.swift
//  suggest
//
//  Created by Rookly on 14.02.2026.
//

import SwiftUI

struct ChipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.15))
            .foregroundColor(.blue)
            .cornerRadius(20)
    }
}

struct ChipRowView: View {
    let chips: [String]
    let offset: CGFloat
    private let repeatCount = 50

    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                ForEach(0..<(chips.count * repeatCount), id: \.self) { index in
                    ChipView(text: chips[index % chips.count])
                        .fixedSize()
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        contentWidth = geo.size.width
                    }
                }
            )
            .offset(x: -contentWidth / 2 + geometry.size.width / 2 + offset)
        }
        .frame(height: 40)
        .clipped()
    }
}

struct ContentView: View {
    let row1 = ["Swift", "iOS", "SwiftUI", "Xcode", "Apple", "Design"]
    let row2 = ["Mobile", "Development", "UIKit", "Combine", "Core Data", "CloudKit"]

    @State private var baseOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var autoOffset: CGFloat = 0
    @State private var velocity: CGFloat = 0
    @State private var lastDragValue: DragGesture.Value?
    @State private var isDragging = false
    @State private var autoScrollPaused = false
    @State private var resumeTask: DispatchWorkItem?

    let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()

    let speed1: CGFloat = -0.5
    let speed2: CGFloat = -0.8
    let friction: CGFloat = 0.95

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ChipRowView(chips: row1, offset: baseOffset + dragOffset + autoOffset * speed1)
            ChipRowView(chips: row2, offset: baseOffset + dragOffset + autoOffset * speed2)

            Spacer()
        }
        .padding(.top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    autoScrollPaused = true
                    resumeTask?.cancel()

                    if let last = lastDragValue {
                        velocity = value.translation.width - last.translation.width
                    }
                    lastDragValue = value
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    isDragging = false
                    baseOffset += value.translation.width
                    dragOffset = 0
                    lastDragValue = nil

                    if abs(velocity) <= 0.1 {
                        scheduleAutoScrollResume()
                    }
                }
        )
        .onReceive(timer) { _ in
            if !autoScrollPaused {
                autoOffset += 1
            }

            if abs(velocity) > 0.1 {
                baseOffset += velocity
                velocity *= friction
            } else if velocity != 0 {
                velocity = 0
                if !isDragging {
                    scheduleAutoScrollResume()
                }
            }
        }
    }

    private func scheduleAutoScrollResume() {
        resumeTask?.cancel()
        let task = DispatchWorkItem {
            autoScrollPaused = false
        }
        resumeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
    }
}

#Preview {
    ContentView()
}
