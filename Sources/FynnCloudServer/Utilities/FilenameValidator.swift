import Vapor

public struct FilenameValidator: Sendable {
    public static let maxLength = 255

    /// Characters prohibited on POSIX / Windows / WebDAV:
    /// `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`, null byte (`\0`), and ASCII control characters (`0x00`–`0x1F`, `0x7F`)
    public static let illegalCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\:*?\"<>|")
        set.formUnion(CharacterSet(charactersIn: "\0"))
        set.formUnion(CharacterSet.controlCharacters)
        return set
    }()

    /// Windows reserved device names (case-insensitive, matched with or without file extension)
    public static let reservedDeviceNames: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ]

    /// Validates a filename for creation or renaming. Throws an `Abort(.badRequest)` error with localized message if invalid.
    public static func validate(filename: String) throws {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw Abort(.badRequest, reason: "Filename cannot be empty.")
                .localized(LocalizationKeys.Error.Files.InvalidFilename)
        }

        if filename.utf8.count > maxLength {
            throw Abort(.badRequest, reason: "Filename cannot exceed \(maxLength) characters.")
                .localized(LocalizationKeys.Error.Files.FilenameTooLong)
        }

        if trimmed == "." || trimmed == ".." {
            throw Abort(.badRequest, reason: "Filename cannot be '.' or '..'.")
                .localized(LocalizationKeys.Error.Files.InvalidFilename)
        }

        if filename.rangeOfCharacter(from: illegalCharacters) != nil {
            throw Abort(.badRequest, reason: "Filename contains prohibited characters.")
                .localized(LocalizationKeys.Error.Files.InvalidFilenameChars)
        }

        if filename.hasSuffix(".") || filename.hasSuffix(" ") {
            throw Abort(.badRequest, reason: "Filename cannot end with a dot or space.")
                .localized(LocalizationKeys.Error.Files.InvalidFilename)
        }

        // Check Windows reserved names (e.g., "con", "aux.txt", "NUL.tar.gz")
        let baseName = ((filename as NSString).deletingPathExtension as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rootName = baseName.components(separatedBy: ".").first ?? baseName
        if reservedDeviceNames.contains(baseName) || reservedDeviceNames.contains(rootName) {
            throw Abort(.badRequest, reason: "Filename is a reserved device name.")
                .localized(LocalizationKeys.Error.Files.InvalidFilename)
        }
    }

    /// Returns whether a filename is valid.
    public static func isValid(filename: String) -> Bool {
        do {
            try validate(filename: filename)
            return true
        } catch {
            return false
        }
    }

    /// Cleans and sanitizes a filename for safe storage across filesystems.
    /// Extracts the basename if a path was passed, strips/replaces illegal characters with '_',
    /// trims whitespace and trailing dots, fixes reserved names, and caps length to maxLength.
    public static func sanitize(filename: String) -> String {
        // Strip any directory path components (both UNIX / and Windows \)
        var clean = filename
        if let lastUnix = clean.components(separatedBy: "/").last {
            clean = lastUnix
        }
        if let lastWin = clean.components(separatedBy: "\\").last {
            clean = lastWin
        }

        // Replace illegal characters and control characters with '_'
        var sanitizedScalars: [Unicode.Scalar] = []
        for scalar in clean.unicodeScalars {
            if illegalCharacters.contains(scalar) {
                sanitizedScalars.append("_")
            } else {
                sanitizedScalars.append(scalar)
            }
        }
        clean = String(String.UnicodeScalarView(sanitizedScalars))

        // Trim leading and trailing whitespace
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        // Trim trailing dots
        while clean.hasSuffix(".") {
            clean.removeLast()
        }

        // Check for empty or reserved relative names
        if clean.isEmpty || clean == "." || clean == ".." {
            clean = "unnamed"
        }

        // Check Windows reserved device names
        let baseName = ((clean as NSString).deletingPathExtension as String).lowercased()
        let rootName = baseName.components(separatedBy: ".").first ?? baseName
        if reservedDeviceNames.contains(baseName) || reservedDeviceNames.contains(rootName) {
            clean = "_\(clean)"
        }

        // Truncate to maxLength if necessary
        if clean.utf8.count > maxLength {
            let ext = (clean as NSString).pathExtension
            if !ext.isEmpty && ext.utf8.count < 30 {
                let nameWithoutExt = (clean as NSString).deletingPathExtension
                let maxBaseBytes = maxLength - ext.utf8.count - 1
                let prefixCount = min(nameWithoutExt.utf8.count, maxBaseBytes)
                let truncatedBase = String(nameWithoutExt.prefix(prefixCount))
                clean = "\(truncatedBase).\(ext)"
            } else {
                clean = String(clean.prefix(maxLength))
            }
        }

        return clean.isEmpty ? "unnamed" : clean
    }
}
