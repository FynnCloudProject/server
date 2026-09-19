import Foundation

/// Encodes an `Email` into an RFC 5322 MIME formatted message.
public struct EmailMimeEncoder: Sendable {

    public init() { }

    /// Encodes an email message to a standard RFC 5322 MIME string.
    ///
    /// - Parameters:
    ///   - email: The email to encode.
    ///   - defaultFrom: Fallback from address if `email.from` is nil.
    ///   - hostname: Hostname to use for Message-ID generation.
    /// - Returns: The formatted MIME string with CRLF line endings.
    public func encode(
        _ email: Email,
        defaultFrom: EmailAddress? = nil,
        hostname: String = "localhost"
    ) -> String {
        let fromAddress = email.from ?? defaultFrom ?? EmailAddress(address: "no-reply@\(hostname)")
        var headers: [(String, String)] = []

        headers.append(("Date", rfc2822Date(Date())))
        headers.append(("From", fromAddress.description))
        headers.append(("To", email.to.map(\.description).joined(separator: ", ")))

        if !email.cc.isEmpty {
            headers.append(("Cc", email.cc.map(\.description).joined(separator: ", ")))
        }

        if !email.replyTo.isEmpty {
            headers.append(("Reply-To", email.replyTo.map(\.description).joined(separator: ", ")))
        }

        headers.append(("Subject", encodeSubject(email.subject)))
        headers.append(("Message-ID", "<\(email.id.uuidString.lowercased())@\(hostname)>"))
        headers.append(("MIME-Version", "1.0"))

        // Add custom headers (avoiding duplicate Bcc or critical standard headers)
        for (key, value) in email.headers {
            let lower = key.lowercased()
            if lower != "bcc" && lower != "to" && lower != "from" && lower != "date" && lower != "subject" {
                headers.append((key, value))
            }
        }

        let inlineAttachments = email.attachments.filter { $0.contentID != nil }
        let regularAttachments = email.attachments.filter { $0.contentID == nil }
        var mimeOutput = ""

        if regularAttachments.isEmpty && !inlineAttachments.isEmpty {
            // Case 1: Inline attachments only -> RFC 2387 multipart/related root
            let relatedBoundary = "related_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            headers.append(("Content-Type", "multipart/related; boundary=\"\(relatedBoundary)\""))

            for (k, v) in headers {
                mimeOutput += "\(k): \(v)\r\n"
            }
            mimeOutput += "\r\n"

            // Body part
            mimeOutput += "--\(relatedBoundary)\r\n"
            mimeOutput += encodeBodyPart(email.body)
            mimeOutput += "\r\n"

            // Inline attachments
            for attachment in inlineAttachments {
                mimeOutput += "--\(relatedBoundary)\r\n"
                mimeOutput += encodeAttachment(attachment)
                mimeOutput += "\r\n"
            }

            mimeOutput += "--\(relatedBoundary)--\r\n"
        } else if !regularAttachments.isEmpty && inlineAttachments.isEmpty {
            // Case 2: Regular file attachments only -> multipart/mixed root
            let mixedBoundary = "mixed_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            headers.append(("Content-Type", "multipart/mixed; boundary=\"\(mixedBoundary)\""))

            for (k, v) in headers {
                mimeOutput += "\(k): \(v)\r\n"
            }
            mimeOutput += "\r\n"

            // Body part
            mimeOutput += "--\(mixedBoundary)\r\n"
            mimeOutput += encodeBodyPart(email.body)
            mimeOutput += "\r\n"

            // Regular file attachments
            for attachment in regularAttachments {
                mimeOutput += "--\(mixedBoundary)\r\n"
                mimeOutput += encodeAttachment(attachment)
                mimeOutput += "\r\n"
            }

            mimeOutput += "--\(mixedBoundary)--\r\n"
        } else if !regularAttachments.isEmpty && !inlineAttachments.isEmpty {
            // Case 3: Both inline and regular attachments -> multipart/mixed containing multipart/related
            let mixedBoundary = "mixed_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let relatedBoundary = "related_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            headers.append(("Content-Type", "multipart/mixed; boundary=\"\(mixedBoundary)\""))

            for (k, v) in headers {
                mimeOutput += "\(k): \(v)\r\n"
            }
            mimeOutput += "\r\n"

            // Related part within mixed
            mimeOutput += "--\(mixedBoundary)\r\n"
            mimeOutput += "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n\r\n"
            mimeOutput += "--\(relatedBoundary)\r\n"
            mimeOutput += encodeBodyPart(email.body)
            mimeOutput += "\r\n"

            for attachment in inlineAttachments {
                mimeOutput += "--\(relatedBoundary)\r\n"
                mimeOutput += encodeAttachment(attachment)
                mimeOutput += "\r\n"
            }
            mimeOutput += "--\(relatedBoundary)--\r\n"

            // Regular attachment parts
            for attachment in regularAttachments {
                mimeOutput += "--\(mixedBoundary)\r\n"
                mimeOutput += encodeAttachment(attachment)
                mimeOutput += "\r\n"
            }

            mimeOutput += "--\(mixedBoundary)--\r\n"
        } else {
            let (bodyHeaders, bodyContent) = encodeStandaloneBody(email.body)
            for (k, v) in headers {
                mimeOutput += "\(k): \(v)\r\n"
            }
            for (k, v) in bodyHeaders {
                mimeOutput += "\(k): \(v)\r\n"
            }
            mimeOutput += "\r\n"
            mimeOutput += bodyContent
        }

        return mimeOutput
    }

    // MARK: - Private Helpers

    private func encodeStandaloneBody(_ body: EmailBody) -> (headers: [(String, String)], content: String) {
        switch body {
        case .plain(let text):
            return (
                [
                    ("Content-Type", "text/plain; charset=utf-8"),
                    ("Content-Transfer-Encoding", "8bit")
                ],
                normalizeCRLF(text) + "\r\n"
            )

        case .html(let html):
            return (
                [
                    ("Content-Type", "text/html; charset=utf-8"),
                    ("Content-Transfer-Encoding", "8bit")
                ],
                normalizeCRLF(html) + "\r\n"
            )

        case .both(let plain, let html):
            let altBoundary = "alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            var content = ""
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/plain; charset=utf-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += normalizeCRLF(plain) + "\r\n"
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=utf-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += normalizeCRLF(html) + "\r\n"
            content += "--\(altBoundary)--\r\n"

            return (
                [("Content-Type", "multipart/alternative; boundary=\"\(altBoundary)\"")],
                content
            )
        }
    }

    private func encodeBodyPart(_ body: EmailBody) -> String {
        switch body {
        case .plain(let text):
            return "Content-Type: text/plain; charset=utf-8\r\n"
                + "Content-Transfer-Encoding: 8bit\r\n\r\n"
                + normalizeCRLF(text)

        case .html(let html):
            return "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Transfer-Encoding: 8bit\r\n\r\n"
                + normalizeCRLF(html)

        case .both(let plain, let html):
            let altBoundary = "alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            var part = "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            part += "--\(altBoundary)\r\n"
            part += "Content-Type: text/plain; charset=utf-8\r\n"
            part += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            part += normalizeCRLF(plain) + "\r\n"
            part += "--\(altBoundary)\r\n"
            part += "Content-Type: text/html; charset=utf-8\r\n"
            part += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            part += normalizeCRLF(html) + "\r\n"
            part += "--\(altBoundary)--"
            return part
        }
    }

    private func encodeAttachment(_ attachment: EmailAttachment) -> String {
        let isInline = attachment.contentID != nil
        let disposition = isInline ? "inline" : "attachment"
        var out = "Content-Type: \(attachment.contentType); name=\"\(attachment.filename)\"\r\n"
        out += "Content-Disposition: \(disposition); filename=\"\(attachment.filename)\"\r\n"
        if let cid = attachment.contentID {
            out += "Content-ID: <\(cid)>\r\n"
        }
        out += "Content-Transfer-Encoding: base64\r\n\r\n"
        out += attachment.data.base64EncodedString(options: .lineLength76Characters)
        return out
    }

    private func encodeSubject(_ subject: String) -> String {
        if subject.allSatisfy({ $0.isASCII && $0 != "?" && $0 != "=" }) {
            return subject
        }
        let base64 = Data(subject.utf8).base64EncodedString()
        return "=?UTF-8?B?\(base64)?="
    }

    private func rfc2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func normalizeCRLF(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }
}
