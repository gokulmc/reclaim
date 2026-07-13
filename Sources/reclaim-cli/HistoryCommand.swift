import ArgumentParser
import Foundation
import ReclaimKit

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show past clean runs."
    )

    func run() async throws {
        let store = HistoryStore()
        let entries = try store.load()

        guard !entries.isEmpty else {
            print("No history yet — run `reclaim-cli clean --run` to record one.")
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        print(pad("DATE", 18) + pad("BACKEND", 18) + pad("TRIMMED", 12) + "HOST DELTA")
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            print(
                pad(dateFormatter.string(from: entry.date), 18)
                + pad(entry.backend.displayName, 18)
                + pad(formatBytes(entry.trimmedBytes), 12)
                + formatBytes(entry.hostDelta)
            )
        }
    }
}
