import Foundation

extension URL {
    /// The absolute path with `.`, `..` and symbolic links resolved and no trailing slash, so
    /// two URLs name the same item exactly when their canonical paths are equal.
    public var canonicalPath: String {
        let path = standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
