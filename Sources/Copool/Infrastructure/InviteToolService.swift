import Foundation

enum InviteToolServiceError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case badPayload

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "接口地址无效。"
        case .invalidResponse:
            return "接口返回了不可识别的响应。"
        case .badPayload:
            return "接口返回的数据无法解析。"
        }
    }
}

struct InviteToolService: InviteToolServiceProtocol {
    let baseURL: URL
    let session: URLSession

    init(
        baseURL: URL = URL(string: "https://team.654301.xyz")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func redeem(code: String, email: String) async throws -> InviteToolResponsePayload {
        try await post(
            path: "/api/redeem/",
            form: [
                "code": code,
                "email": email,
            ]
        )
    }

    func checkWarranty(code: String) async throws -> InviteToolResponsePayload {
        try await post(
            path: "/api/warranty/activate/",
            form: [
                "codes": code,
            ]
        )
    }

    func redeemWarranty(code: String, email: String, lastUsedEmail: String) async throws -> InviteToolResponsePayload {
        try await post(
            path: "/api/warranty/redeem/",
            form: [
                "code": code,
                "email": email,
                "last_used_email": lastUsedEmail,
            ]
        )
    }

    func queryStatus(code: String) async throws -> InviteToolResponsePayload {
        try await post(
            path: "/api/status/",
            form: [
                "code": code,
            ]
        )
    }

    private func post(path: String, form: [String: String]) async throws -> InviteToolResponsePayload {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw InviteToolServiceError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = encodedForm(form)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        let (data, response) = try await session.data(for: request)
        guard response is HTTPURLResponse else {
            throw InviteToolServiceError.invalidResponse
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(InviteToolResponsePayload.self, from: data) else {
            throw InviteToolServiceError.badPayload
        }
        return payload
    }

    private func encodedForm(_ form: [String: String]) -> Data? {
        let body = form
            .map { key, value in
                let encodedKey = percentEncodeFormComponent(key)
                let encodedValue = percentEncodeFormComponent(value)
                return "\(encodedKey)=\(encodedValue)"
            }
            .sorted()
            .joined(separator: "&")
        return body.data(using: .utf8)
    }

    private func percentEncodeFormComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? value
    }
}
