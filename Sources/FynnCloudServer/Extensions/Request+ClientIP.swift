import Vapor

extension Request {
    /// Resolves the real client IP address from proxy headers, falling back to the socket peer address.
    /// Supports Cloudflare (`CF-Connecting-IP`, `True-Client-IP`), standard `X-Forwarded-For`,
    /// and direct reverse proxy `X-Real-IP`.
    public var clientIP: String {
        // Cloudflare / CDN specific headers
        if let cfIP = headers["CF-Connecting-IP"].first?.trimmingCharacters(in: .whitespaces),
            !cfIP.isEmpty
        {
            return cfIP
        }
        if let trueClientIP = headers["True-Client-IP"].first?.trimmingCharacters(in: .whitespaces),
            !trueClientIP.isEmpty
        {
            return trueClientIP
        }

        // Standard X-Forwarded-For (leftmost entry is original client IP)
        if let forwardedFor = headers["X-Forwarded-For"].first?.split(separator: ",").first {
            let ip = String(forwardedFor).trimmingCharacters(in: .whitespaces)
            if !ip.isEmpty {
                return ip
            }
        }

        if let realIP = headers["X-Real-IP"].first?.trimmingCharacters(in: .whitespaces),
            !realIP.isEmpty
        {
            return realIP
        }

        // Fallback socket peer address
        return peerAddress?.ipAddress ?? "unknown"
    }
}
