import Foundation

/// "You've written 3 postcards!" style comparisons for the total words tile.
enum FlowFunFacts {
    private static let table: [(upperBound: Int, divisor: Int, object: String)] = [
        (50, 5, "thank-you note"),
        (100, 10, "meme caption"),
        (200, 10, "thank-you note"),
        (350, 14, "meme caption"),
        (1_000, 50, "postcard"),
        (2_000, 100, "folk tale"),
        (3_000, 200, "wedding vow"),
        (5_000, 300, "tweet"),
        (6_000, 500, "news article"),
        (7_000, 700, "cover letter"),
        (10_000, 900, "email newsletter"),
        (15_000, 7_500, "instruction manual"),
        (20_000, 9_000, "picture book"),
        (30_000, 10_000, "college essay"),
        (50_000, 4_300, "short film script"),
        (70_000, 35_000, "book chapter"),
        (100_000, 35_000, "podcast season"),
    ]
    private static let above = (divisor: 100_000, object: "complete book")

    static func fact(forWords words: Int) -> String? {
        guard words > 0 else { return nil }
        let row = table.first(where: { $0.upperBound >= words })
        let divisor = row?.divisor ?? above.divisor
        let object = row?.object ?? above.object
        let n = words / divisor
        guard n > 0 else { return nil }
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "You've written \(formatted) \(object)\(n == 1 ? "" : "s")!"
    }
}
