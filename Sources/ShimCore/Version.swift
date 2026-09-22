import Foundation

/// Package-wide build metadata. Named to avoid colliding with the executable's
/// `@main struct AFMServer`.
public enum AFMBuild {
    /// Semantic version of afm-server. Keep in sync with the git tag (`vX.Y.Z`).
    public static let version = "0.1.0"
}
