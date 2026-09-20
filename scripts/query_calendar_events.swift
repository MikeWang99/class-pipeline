#!/usr/bin/swift

import EventKit
import Foundation

let calendar = Calendar.current
let argument = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1"
let target: Date

if let offset = Int(argument) {
    guard let computed = calendar.date(byAdding: .day, value: offset, to: Date()) else {
        fputs("failed to compute target date\n", stderr); exit(1)
    }
    target = computed
} else {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    guard let parsed = formatter.date(from: argument) else {
        fputs("invalid date argument: expected day offset or yyyy-MM-dd\n", stderr); exit(1)
    }
    target = parsed
}

let start = calendar.startOfDay(for: target)
guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
    fputs("failed to compute end date\n", stderr); exit(1)
}

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

func clean(_ value: String?) -> String {
    return (value ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

func printEvents() {
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: predicate).sorted { lhs, rhs in
        if lhs.startDate == rhs.startDate { return (lhs.title ?? "") < (rhs.title ?? "") }
        return lhs.startDate < rhs.startDate
    }
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone.current
    formatter.formatOptions = [.withInternetDateTime]
    for event in events {
        let summary = clean(event.title)
        let startText = formatter.string(from: event.startDate)
        let endText = formatter.string(from: event.endDate)
        let identifier = clean(event.eventIdentifier ?? event.calendarItemIdentifier)
        let notes = clean(event.notes)
        print("\(summary)\t\(startText)\t\(endText)\t\(identifier)\t\(notes)")
    }
}

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { granted, error in
        defer { semaphore.signal() }
        if let error { fputs("calendar access error: \(error.localizedDescription)\n", stderr); exitCode = 1; return }
        guard granted else { fputs("calendar access denied\n", stderr); exitCode = 1; return }
        printEvents()
    }
} else {
    store.requestAccess(to: .event) { granted, error in
        defer { semaphore.signal() }
        if let error { fputs("calendar access error: \(error.localizedDescription)\n", stderr); exitCode = 1; return }
        guard granted else { fputs("calendar access denied\n", stderr); exitCode = 1; return }
        printEvents()
    }
}
semaphore.wait()
exit(exitCode)
