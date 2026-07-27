//
//  StatsView.swift
//  Canary
//
//  Created by Claude on 7/27/26.
//

import Charts
import SwiftUI

/// Typing statistics over the keyboard's opt-in event streams. Every chart is
/// a single series of magnitudes, so the whole screen uses one chart hue and
/// no legends; headline figures are plain rows, not charts.
struct StatsView: View {
    @State private var summary = DictionaryStore.StatsSummary()
    @State private var hours: [DictionaryStore.HourActivity] = []
    @State private var days: [DictionaryStore.DayActivity] = []
    @State private var words: [DictionaryStore.WordCount] = []
    @State private var learnedGrowth: [DictionaryStore.DayActivity] = []
    @State private var wpmByDay: [DayMetric] = []
    @State private var backspaceRateByDay: [DayMetric] = []
    @State private var slowestPairs: [PairLatency] = []
    @State private var swipeShare: [DictionaryStore.DayShare] = []
    @State private var medianDecodeMS: Double?
    @State private var storeAvailable = false

    struct DayMetric: Identifiable {
        let day: Date
        let value: Double
        var id: Date { day }
    }

    struct PairLatency: Identifiable {
        let pair: String
        let ms: Double
        var id: String { pair }
    }

    /// The one hue every chart on this screen wears (adapts to dark mode).
    private let chartColor = Color.teal

    var body: some View {
        Group {
            if !storeAvailable {
                unavailableExplainer
            } else if !KeyboardSettings.statsCollectionEnabled && summary.keystrokes == 0 {
                ContentUnavailableView {
                    Label("Stats are off", systemImage: "chart.bar")
                } description: {
                    Text("Turn on Collect Typing Stats in Settings, then type a while. Collection is per-device and opt-in.")
                }
            } else {
                statsList
            }
        }
        .navigationTitle("Stats")
        .onAppear(perform: reload)
    }

    private var statsList: some View {
        List {
            Section("At a Glance") {
                LabeledContent("Keystrokes (90 days)", value: summary.keystrokes.formatted())
                LabeledContent("Words typed (90 days)", value: summary.wordsTyped.formatted())
                LabeledContent("Words learned", value: summary.wordsLearned.formatted())
                if summary.swipeCommits > 0 {
                    LabeledContent("Swipe accuracy", value: percent(
                        1 - Double(summary.swipeCorrections) / Double(summary.swipeCommits)))
                }
                if summary.autocorrectApplied + summary.autocorrectRejected > 0 {
                    // Silent reverts (backspace right after an apply) count as
                    // rejections; the bar-tap number alone flatters autocorrect.
                    LabeledContent("Autocorrects kept", value: percent(
                        max(0, Double(summary.autocorrectApplied - summary.autocorrectReverted))
                            / Double(summary.autocorrectApplied + summary.autocorrectRejected)))
                }
                if summary.charsSavedByShortcuts > 0 {
                    LabeledContent("Characters saved by shortcuts",
                                   value: summary.charsSavedByShortcuts.formatted())
                }
                if let medianDecodeMS {
                    LabeledContent("Median swipe decode",
                                   value: "\(medianDecodeMS.formatted(.number.precision(.fractionLength(1)))) ms")
                }
            }

            if wpmByDay.count >= 2 {
                Section("Typing Speed (30 days)") {
                    Chart(wpmByDay) { item in
                        LineMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("WPM", item.value)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .frame(height: 140)
                    .padding(.vertical, 4)
                }
            }

            if hours.contains(where: { $0.count > 0 }) {
                Section("Active Hours (30 days)") {
                    Chart(hours) { item in
                        BarMark(
                            x: .value("Hour", item.hour),
                            y: .value("Keystrokes", item.count)
                        )
                        .foregroundStyle(chartColor)
                        .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let hour = value.as(Int.self) {
                                    Text(hourLabel(hour))
                                }
                            }
                        }
                    }
                    .chartXScale(domain: -1...24)
                    .frame(height: 160)
                    .padding(.vertical, 4)
                }
            }

            if days.contains(where: { $0.count > 0 }) {
                Section("Daily Activity (14 days)") {
                    Chart(days) { item in
                        BarMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("Keystrokes", item.count)
                        )
                        .foregroundStyle(chartColor)
                        .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 160)
                    .padding(.vertical, 4)
                }
            }

            if slowestPairs.count >= 3 {
                Section {
                    Chart(slowestPairs) { item in
                        BarMark(
                            x: .value("Latency", item.ms),
                            y: .value("Pair", item.pair)
                        )
                        .foregroundStyle(chartColor)
                        .cornerRadius(2)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("\(Int(item.ms)) ms")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(slowestPairs.count) * 28 + 16)
                    .padding(.vertical, 4)
                } header: {
                    Text("Slowest Key Pairs (30 days)")
                } footer: {
                    Text("Mean time between the two key presses, for pairs typed at least 15 times. The layout report card.")
                }
            }

            if backspaceRateByDay.count >= 2 {
                Section("Backspace Rate (30 days)") {
                    Chart(backspaceRateByDay) { item in
                        LineMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("Rate", item.value)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let rate = value.as(Double.self) {
                                    Text(rate.formatted(.percent.precision(.fractionLength(0))))
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                    .padding(.vertical, 4)
                }
            }

            if swipeShare.count >= 2 {
                Section("Words Entered by Swipe (30 days)") {
                    Chart(swipeShare) { item in
                        LineMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("Share", item.share)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYScale(domain: 0...1)
                    .chartYAxis {
                        AxisMarks(values: [0, 0.5, 1]) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let share = value.as(Double.self) {
                                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                    .padding(.vertical, 4)
                }
            }

            if !words.isEmpty {
                Section("Top Words (30 days)") {
                    Chart(words) { item in
                        BarMark(
                            x: .value("Times typed", item.count),
                            y: .value("Word", item.word)
                        )
                        .foregroundStyle(chartColor)
                        .cornerRadius(2)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(item.count.formatted())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(words.count) * 28 + 16)
                    .padding(.vertical, 4)
                }
            }

            if learnedGrowth.count >= 2 {
                Section("Words Learned Over Time") {
                    Chart(learnedGrowth) { item in
                        LineMark(
                            x: .value("Date", item.day),
                            y: .value("Words", item.count)
                        )
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.stepEnd)
                    }
                    .frame(height: 140)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var unavailableExplainer: some View {
        ContentUnavailableView {
            Label("Stats unavailable", systemImage: "lock")
        } description: {
            Text("Enable Full Access for the Canary keyboard in Settings › General › Keyboard › Keyboards, then use the keyboard once.")
        }
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private func reload() {
        guard let store = DictionaryStore() else {
            storeAvailable = false
            return
        }
        storeAvailable = true
        summary = store.statsSummary()
        hours = store.keystrokesByHour(days: 30)
        days = store.keystrokesByDay(days: 14)
        words = store.topWords(days: 30, limit: 10)
        learnedGrowth = store.learnedWordGrowth()
        swipeShare = store.swipeShareByDay(days: 30)
        let durations = store.swipeDecodeDurations(days: 30).sorted()
        medianDecodeMS = durations.isEmpty ? nil : durations[durations.count / 2]
        computeDerived(store.typingEvents(days: 30))
    }

    /// Sessionizes the raw event stream client-side: WPM per day (chars/5 over
    /// active time, where gaps cap at 5s so pauses don't count), backspace
    /// rate per day, and mean latency per letter pair — the layout's report
    /// card, measured on real fingers instead of modeled.
    private func computeDerived(_ events: [DictionaryStore.TypingEvent]) {
        let calendar = Calendar.current
        var perDay: [Date: (chars: Int, backspaces: Int, active: Double, lastAt: Double?)] = [:]
        var pairs: [String: (total: Double, count: Int)] = [:]
        var previous: DictionaryStore.TypingEvent?

        for event in events {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: event.at))
            var bucket = perDay[day] ?? (0, 0, 0, nil)
            // Raw kind values mirror the keyboard's KeyEventKind (no shared
            // code across targets): 0 character, 1 space, 2 backspace.
            if event.kind == 2 {
                bucket.backspaces += 1
            } else {
                bucket.chars += 1
            }
            if let last = bucket.lastAt {
                bucket.active += min(event.at - last, 5)
            }
            bucket.lastAt = event.at
            perDay[day] = bucket

            if let previous,
               previous.kind == 0, event.kind == 0,
               let first = previous.key?.lowercased(), let second = event.key?.lowercased(),
               first.count == 1, second.count == 1,
               first.first!.isLetter, second.first!.isLetter {
                let gap = event.at - previous.at
                // 30ms floor drops key-repeat artifacts; 1.5s cap drops pauses.
                if gap > 0.03, gap < 1.5 {
                    var entry = pairs[first + second] ?? (0, 0)
                    entry.total += gap * 1000
                    entry.count += 1
                    pairs[first + second] = entry
                }
            }
            previous = event
        }

        wpmByDay = perDay.compactMap { day, bucket in
            guard bucket.chars >= 100, bucket.active >= 30 else { return nil }
            return DayMetric(day: day, value: Double(bucket.chars) / 5 / (bucket.active / 60))
        }.sorted { $0.day < $1.day }

        backspaceRateByDay = perDay.compactMap { day, bucket in
            let presses = bucket.chars + bucket.backspaces
            guard presses >= 100 else { return nil }
            return DayMetric(day: day, value: Double(bucket.backspaces) / Double(presses))
        }.sorted { $0.day < $1.day }

        slowestPairs = Array(
            pairs.compactMap { pair, entry in
                entry.count >= 15 ? PairLatency(pair: pair, ms: entry.total / Double(entry.count)) : nil
            }
            .sorted { $0.ms > $1.ms }
            .prefix(8)
        )
    }
}

#Preview {
    NavigationStack {
        StatsView()
    }
}
