import Foundation

/// Separates provider ranking from the rows the user is actively navigating.
/// New provider results may append during keyboard navigation, but existing
/// rows never move underneath the selection for the same query.
enum SearchSelectionCoordinator {
    static func orderedResults(
        current: [LauncherItem],
        incoming: [LauncherItem],
        preserveCurrentOrder: Bool
    ) -> [LauncherItem] {
        guard preserveCurrentOrder else { return incoming }
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let currentIDs = Set(current.map { $0.id })
        let survivors = current.compactMap { incomingByID[$0.id] }
        return survivors + incoming.filter { !currentIDs.contains($0.id) }
    }

    static func selectedIndex(
        in results: [LauncherItem],
        preferredID: String?,
        previousIndex: Int,
        isActionable: (LauncherItem) -> Bool
    ) -> Int {
        if let preferredID, let index = results.firstIndex(where: { $0.id == preferredID }) {
            return index
        }
        let actionable = results.indices.filter { isActionable(results[$0]) }
        guard !actionable.isEmpty else { return 0 }
        guard preferredID != nil else { return actionable[0] }
        return actionable.min { left, right in
            let leftDistance = abs(left - previousIndex)
            let rightDistance = abs(right - previousIndex)
            return leftDistance == rightDistance ? left < right : leftDistance < rightDistance
        } ?? actionable[0]
    }
}
