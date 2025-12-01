import AppKit

extension NSMenu {
    /// Inserts a menu item after an existing item with the specified action selector.
    ///
    /// If an item with the same identifier already exists, it is removed first to avoid duplicates.
    /// This is useful when menus are cached and reused across different targets.
    ///
    /// - Parameters:
    ///   - item: The menu item to insert.
    ///   - action: The action selector to search for. The new item will be inserted after the first
    ///             item with this action.
    /// - Returns: The index where the item was inserted, or `nil` if the action was not found
    ///            and the item was not inserted.
    @discardableResult
    func insertItem(_ item: NSMenuItem, after action: Selector) -> UInt? {
        if let identifier = item.identifier,
           let existing = items.first(where: { $0.identifier == identifier }) {
            removeItem(existing)
        }

        guard let idx = items.firstIndex(where: { $0.action == action }) else {
            return nil
        }

        let insertionIndex = idx + 1
        insertItem(item, at: insertionIndex)
        return UInt(insertionIndex)
    }
}
