#if os(macOS) && STABILITY
enum FinderCopyCancellationState { case waiting, cancellable, finished }

enum FinderCopyCancellationTarget {
    /// Finder's copy preparation shows both quoted names while it hydrates the
    /// source. A generic progress window or a shared name alone is insufficient.
    static func matches(sourceName: String, destinationName: String, labels: [String]) -> Bool {
        guard !sourceName.isEmpty, !destinationName.isEmpty,
              sourceName != destinationName else { return false }
        return labels.contains { $0.contains("“" + sourceName + "”") } &&
            labels.contains { $0.contains("“" + destinationName + "”") }
    }
}
#endif
