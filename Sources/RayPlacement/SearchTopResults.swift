import Foundation

/// Keeps only the best visible results as the catalog is scanned. Memory and
/// sorting cost depend on the result limit rather than the number of matches.
struct SearchTopResults<Element> {
    private(set) var elements: [Element] = []
    let limit: Int
    let precedes: (Element, Element) -> Bool

    mutating func insert(_ value: Element) {
        guard limit > 0 else { return }
        if elements.count == limit, let last = elements.last, !precedes(value, last) { return }
        var low = 0
        var high = elements.count
        while low < high {
            let middle = (low + high) / 2
            if precedes(value, elements[middle]) { high = middle }
            else { low = middle + 1 }
        }
        elements.insert(value, at: low)
        if elements.count > limit { elements.removeLast() }
    }
}
