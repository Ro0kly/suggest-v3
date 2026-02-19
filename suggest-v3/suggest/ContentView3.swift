//
//  ContentView3.swift
//  suggest
//
//  Created by Rookly on 14.02.2026.
//

import SwiftUI
import SwiftUIIntrospect

// MARK: - Model

struct Chip3: Identifiable {
    let id: String
    let text: String

    init(_ text: String, index: Int) {
        self.id = "\(text)-\(index)"
        self.text = text
    }
}

// MARK: - Chip View

struct ChipView3: View {
    let chip: Chip3

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

struct ChipRowView3: View {
    let chips: [Chip3]
    let autoOffset: CGFloat
    let onTap: (Chip3) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(chips) { chip in
                ChipView3(chip: chip)
                    .onTapGesture {
                        onTap(chip)
                    }
            }
        }
        .padding(.horizontal)
        .offset(x: autoOffset)
    }
}

// MARK: - ContentView3

struct ContentView3: View {
    private let repeatCount = 30
    private let baseRow1 = ["Check my balance", "Recent transactions", "Transfer money", "Pay bills", "Card limits"]
    private let baseRow2 = ["Open new account", "Exchange rates", "Find ATM nearby", "Block my card", "Loan calculator"]

    @State private var row1: [Chip3] = []
    @State private var row2: [Chip3] = []

    @State private var autoOffset1: CGFloat = 0
    @State private var autoOffset2: CGFloat = 0
    @State private var isUserScrolling = false
    @State private var resumeTask: DispatchWorkItem?

    let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()
    let speed1: CGFloat = -0.3
    let speed2: CGFloat = -0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggestions")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ChipRowView3(chips: row1, autoOffset: autoOffset1) { chip in
                        print("Tapped: \(chip.text)")
                    }
                    ChipRowView3(chips: row2, autoOffset: autoOffset2) { chip in
                        print("Tapped: \(chip.text)")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18, .v26)) { scrollView in
                scrollView.bounces = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let centerX = (scrollView.contentSize.width - scrollView.bounds.width) / 2
                    if centerX > 0 && scrollView.contentOffset.x == 0 {
                        scrollView.contentOffset.x = centerX
                    }
                }
            }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in
                        isUserScrolling = true
                        resumeTask?.cancel()
                    }
                    .onEnded { _ in
                        scheduleAutoScrollResume()
                    }
            )

            Spacer()
        }
        .padding(.top)
        .onAppear {
            row1 = (0..<repeatCount).flatMap { repeatIndex in
                baseRow1.enumerated().map { index, text in
                    Chip3(text, index: repeatIndex * baseRow1.count + index)
                }
            }
            row2 = (0..<repeatCount).flatMap { repeatIndex in
                baseRow2.enumerated().map { index, text in
                    Chip3(text, index: repeatIndex * baseRow2.count + index)
                }
            }
        }
        .onReceive(timer) { _ in
            guard !isUserScrolling else { return }
            autoOffset1 += speed1
            autoOffset2 += speed2
        }
    }

    private func scheduleAutoScrollResume() {
        resumeTask?.cancel()
        let task = DispatchWorkItem {
            isUserScrolling = false
        }
        resumeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
    }
}

#Preview {
    ContentView3()
}
