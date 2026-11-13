import AuthenticationServices
import Foundation

/// Lepak 账号。用 Apple 登录（Sign in with Apple），以后做订阅用。
struct Account: Equatable {
    /// Apple 给 Lepak 的用户 ID，同一个 Apple 账号每次登录都一样。
    let appleUserID: String
    /// 邮箱。用户可能选了「隐藏邮件地址」，那就是 Apple 的转发地址；也可能拿不到。
    var email: String?
}

/// 用 Apple 登录：取出账号、记在本机、检查授权有没有被撤销。
///
/// 现在只在本机记住登录状态：Apple 用户 ID 和邮箱存在 UserDefaults，不存 Apple 给的令牌，也不写进日志。
/// 以后做订阅时，要把登录拿到的 identityToken 交给自己的服务器验证，再在这里接上。
///
/// 能不能登录取决于签名：App 必须用开发者证书签名，并带 Apple 登录的权限和描述文件（见 scripts/package-app.sh），
/// 否则系统直接拒绝请求（错误 1000）。
enum AppleAccount {
    private static let userIDKey = "account.appleUserID"
    private static let emailKey = "account.email"

    /// 本机记住的账号；没登录过是 nil。
    static func load() -> Account? {
        let defaults = UserDefaults.standard
        guard let id = defaults.string(forKey: userIDKey) else { return nil }
        return Account(appleUserID: id, email: defaults.string(forKey: emailKey))
    }

    static func save(_ account: Account?) {
        let defaults = UserDefaults.standard
        if let account {
            defaults.set(account.appleUserID, forKey: userIDKey)
            defaults.set(account.email, forKey: emailKey)
        } else {
            defaults.removeObject(forKey: userIDKey)
            defaults.removeObject(forKey: emailKey)
        }
    }

    /// 从登录结果里取出账号。邮箱只在第一次授权时直接给；以后从 identityToken 里读出来，只用来显示。
    static func account(from authorization: ASAuthorization, previous: Account?) -> Account? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return nil }
        let email = credential.email
            ?? credential.identityToken.flatMap(emailClaim)
            ?? (previous?.appleUserID == credential.user ? previous?.email : nil)
        return Account(appleUserID: credential.user, email: email)
    }

    /// identityToken 是 JWT，中间一段是 base64url 编码的 JSON，里面有 email。这里不验证签名，只读来显示。
    private static func emailClaim(_ token: Data) -> String? {
        guard let jwt = String(data: token, encoding: .utf8) else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["email"] as? String
    }

    /// 登录失败时给用户看的话；用户自己取消的返回 nil，不提示。
    static func message(for error: Error) -> String? {
        if let error = error as? ASAuthorizationError {
            switch error.code {
            case .canceled:
                return nil
            case .unknown:
                return "这个版本还不能用 Apple 登录：需要用开发者证书签名的正式版。"
            default:
                break
            }
        }
        return "登录没有成功：\(error.localizedDescription)"
    }

    /// 问 Apple 这个账号是不是已经撤销了对 Lepak 的授权（用户可能在系统设置里撤销）。
    /// 只有明确是「已撤销」才算；查不到（比如没网、签名不对）不算，免得误把人登出。
    static func checkRevoked(_ userID: String, completion: @escaping @Sendable (Bool) -> Void) {
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
            completion(state == .revoked)
        }
    }
}
