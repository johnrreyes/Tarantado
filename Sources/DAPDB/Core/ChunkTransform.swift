import Foundation

/// Generic tree-rewriting helpers used by the mutation API. Both helpers walk
/// the tree, apply a caller-supplied transform at the matched node(s), and
/// call `recomputeDerivedFields()` on every node whose children may have
/// changed as the recursion unwinds — so a mutation made deep in the tree
/// automatically produces correct `totalLen`/count fields all the way up to
/// the root, without the caller having to track which ancestors to fix up.
extension Chunk {
    /// Depth-first, pre-order: replaces the first descendant (including
    /// `self`) matching `predicate` with `transform(node)`. Returns the
    /// (possibly) new tree and whether a replacement was made.
    func transformingFirstDescendant(
        matching predicate: (Chunk) -> Bool,
        with transform: (Chunk) -> Chunk
    ) -> (chunk: Chunk, changed: Bool) {
        if predicate(self) {
            var copy = transform(self)
            copy.recomputeDerivedFields()
            return (copy, true)
        }
        var copy = self
        for i in copy.children.indices {
            let (newChild, changed) = copy.children[i].transformingFirstDescendant(matching: predicate, with: transform)
            if changed {
                copy.children[i] = newChild
                copy.recomputeDerivedFields()
                return (copy, true)
            }
        }
        return (self, false)
    }

    /// Applies `transform` to every descendant (including `self`) matching
    /// `predicate`, anywhere in the tree.
    func transformingAllDescendants(
        matching predicate: (Chunk) -> Bool,
        with transform: (Chunk) -> Chunk
    ) -> Chunk {
        var copy = self
        copy.children = copy.children.map { $0.transformingAllDescendants(matching: predicate, with: transform) }
        if predicate(copy) {
            copy = transform(copy)
        }
        copy.recomputeDerivedFields()
        return copy
    }
}
