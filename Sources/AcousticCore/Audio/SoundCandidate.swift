import Synchronization

/// Candidate ("New") versions of the worlds, auditioned in Satie Lab before they ship.
/// Off everywhere except when Satie Lab turns it on, so the apps always play the current version.
/// When a candidate is approved, its code becomes the default and its `isOn` checks are removed.
public enum SoundCandidate {
    private static let flag = Atomic<Bool>(false)

    public static var isOn: Bool {
        get { flag.load(ordering: .relaxed) }
        set { flag.store(newValue, ordering: .relaxed) }
    }
}
