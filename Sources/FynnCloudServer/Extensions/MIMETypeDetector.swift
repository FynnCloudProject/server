import Foundation
import Vapor

struct MIMETypeDetector {
    private static let extensionToMIME: [String: String] = [
        // Images
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "bmp": "image/bmp",
        "ico": "image/x-icon",
        "tiff": "image/tiff",
        "tif": "image/tiff",
        "heic": "image/heic",
        "heif": "image/heif",
        "avif": "image/avif",

        // Audio
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",

        // Video
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mov": "video/quicktime",
        "avi": "video/x-msvideo",
        "mkv": "video/x-matroska",

        // Documents & Text
        "pdf": "application/pdf",
        "txt": "text/plain",
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "scss": "text/x-scss",
        "sass": "text/x-sass",
        "less": "text/x-less",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "cjs": "text/javascript",
        "ts": "application/typescript",
        "mts": "application/typescript",
        "cts": "application/typescript",
        "tsx": "text/typescript-jsx",
        "jsx": "text/jsx",
        "vue": "text/x-vue",
        "svelte": "text/x-svelte",
        "json": "application/json",
        "json5": "application/json5",
        "xml": "application/xml",
        "yaml": "text/yaml",
        "yml": "text/yaml",
        "toml": "application/toml",
        "ini": "text/plain",
        "conf": "text/plain",
        "cfg": "text/plain",
        "env": "text/plain",
        "properties": "text/plain",
        "csv": "text/csv",
        "tsv": "text/tab-separated-values",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "log": "text/plain",
        "diff": "text/x-diff",
        "patch": "text/x-diff",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "odt": "application/vnd.oasis.opendocument.text",
        "rtf": "application/rtf",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ods": "application/vnd.oasis.opendocument.spreadsheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odp": "application/vnd.oasis.opendocument.presentation",
        "keynote": "application/vnd.apple.keynote",

        // Programming Languages & Scripts
        "sh": "application/x-sh",
        "bash": "application/x-sh",
        "zsh": "application/x-sh",
        "fish": "application/x-sh",
        "py": "text/x-python",
        "rb": "text/x-ruby",
        "rs": "text/rust",
        "go": "text/x-go",
        "swift": "text/x-swift",
        "c": "text/x-c",
        "cpp": "text/x-c++",
        "cc": "text/x-c++",
        "cxx": "text/x-c++",
        "h": "text/x-c",
        "hpp": "text/x-c++",
        "cs": "text/x-csharp",
        "java": "text/x-java-source",
        "kt": "text/x-kotlin",
        "scala": "text/x-scala",
        "php": "application/x-httpd-php",
        "sql": "application/sql",
        "graphql": "application/graphql",
        "gql": "application/graphql",
        "proto": "text/x-protobuf",
        "lock": "text/plain",

        // Security, Crypto & Certificates
        "key": "application/x-pem-file",
        "pem": "application/x-pem-file",
        "crt": "application/x-x509-ca-cert",
        "cer": "application/x-x509-ca-cert",
        "der": "application/x-x509-ca-cert",
        "pub": "text/plain",
        "asc": "text/plain",
        "gpg": "application/pgp-encrypted",
        "csr": "application/pkcs10",
        "pfx": "application/x-pkcs12",
        "p12": "application/x-pkcs12",

        // Archives
        "zip": "application/zip",
        "tar": "application/x-tar",
        "gz": "application/gzip",
        "rar": "application/vnd.rar",
        "7z": "application/x-7z-compressed"
    ]

    static func detect(filename: String, fallback: String = "application/octet-stream") -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let mime = extensionToMIME[ext] {
            return mime
        }
        if !ext.isEmpty, let mediaType = HTTPMediaType.fileExtension(ext) {
            return mediaType.serialize()
        }
        if !fallback.isEmpty && fallback != "application/octet-stream" {
            return fallback
        }
        return "application/octet-stream"
    }
}
