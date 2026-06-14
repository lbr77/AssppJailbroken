import ApplePackage
import Foundation
import Vapor

enum AppleProtocolService {
    private static let applePackage = ApplePackageExecutor()
    private static let rateLimitCode = "rate_limited"
    private static let rateLimitMessage = "Apple rate limit reached. Wait before trying again."

    static func authenticate(_ request: AppleAuthenticateRequest) async throws -> AppleAccount {
        do {
            try validateDeviceIdentifier(request.deviceIdentifier)
            let account = try await applePackage.authenticate(
                email: request.email,
                password: request.password,
                code: request.code ?? "",
                cookies: request.existingCookies?.applePackageCookies() ?? [],
                deviceIdentifier: request.deviceIdentifier
            )
            return account.webAccount(deviceIdentifier: request.deviceIdentifier)
        } catch let error as AppleProtocolError {
            throw error
        } catch {
            throw protocolError(from: error)
        }
    }

    static func purchase(account: AppleAccount, software: Software) async throws -> AppleAccount {
        guard (software.price ?? 0) <= 0 else {
            throw AppleProtocolError(status: .badRequest, message: "purchasing paid apps is not supported")
        }

        let result = try await runWithTokenRefresh(account: account) { packageAccount, deviceIdentifier in
            let updatedAccount = try await applePackage.purchase(
                account: packageAccount,
                app: software.applePackageSoftware(),
                deviceIdentifier: deviceIdentifier
            )
            return (updatedAccount, ())
        }
        return result.account
    }

    static func downloadInfo(
        account: AppleAccount,
        software: Software,
        externalVersionId: String?
    ) async throws -> (account: AppleAccount, output: AppleDownloadOutput) {
        let result = try await runWithTokenRefresh(account: account) { packageAccount, deviceIdentifier in
            try await applePackage.download(
                account: packageAccount,
                app: software.applePackageSoftware(),
                externalVersionId: externalVersionId,
                deviceIdentifier: deviceIdentifier
            )
        }
        return (account: result.account, output: result.value.webDownloadOutput())
    }

    static func listVersions(account: AppleAccount, software: Software) async throws -> (account: AppleAccount, versions: [String]) {
        let result = try await runWithTokenRefresh(account: account) { packageAccount, deviceIdentifier in
            try await applePackage.listVersions(
                account: packageAccount,
                bundleIdentifier: software.bundleID,
                deviceIdentifier: deviceIdentifier
            )
        }
        return (account: result.account, versions: result.value)
    }

    static func versionMetadata(
        account: AppleAccount,
        software: Software,
        versionId: String
    ) async throws -> (account: AppleAccount, metadata: VersionMetadata) {
        let result = try await runWithTokenRefresh(account: account) { packageAccount, deviceIdentifier in
            try await applePackage.versionMetadata(
                account: packageAccount,
                app: software.applePackageSoftware(),
                versionId: versionId,
                deviceIdentifier: deviceIdentifier
            )
        }
        return (account: result.account, metadata: result.value.webVersionMetadata())
    }

    static func protocolErrorForTesting(_ error: Error) -> AppleProtocolError {
        protocolError(from: error)
    }

    private static func runWithTokenRefresh<T>(
        account: AppleAccount,
        _ operation: (ApplePackage.Account, String) async throws -> (ApplePackage.Account, T)
    ) async throws -> (account: AppleAccount, value: T) {
        do {
            try validateDeviceIdentifier(account.deviceIdentifier)
            let result = try await operation(account.applePackageAccount(), account.deviceIdentifier)
            return (account: result.0.webAccount(deviceIdentifier: account.deviceIdentifier), value: result.1)
        } catch {
            let mappedError = protocolError(from: error)
            guard mappedError.isPasswordTokenExpired else {
                throw mappedError
            }

            let refreshedAccount = try await refreshAccount(account)
            do {
                let result = try await operation(refreshedAccount.applePackageAccount(), refreshedAccount.deviceIdentifier)
                return (account: result.0.webAccount(deviceIdentifier: refreshedAccount.deviceIdentifier), value: result.1)
            } catch {
                throw protocolError(from: error)
            }
        }
    }

    private static func refreshAccount(_ account: AppleAccount) async throws -> AppleAccount {
        try await authenticate(AppleAuthenticateRequest(
            email: account.email,
            password: account.password,
            code: nil,
            existingCookies: account.cookies,
            deviceIdentifier: account.deviceIdentifier
        ))
    }

    private static func validateDeviceIdentifier(_ deviceIdentifier: String) throws {
        guard deviceIdentifier.isEmpty == false else {
            throw AppleProtocolError(status: .badRequest, message: "deviceIdentifier is required")
        }
    }

    private static func protocolError(from error: Error) -> AppleProtocolError {
        if let error = error as? AppleProtocolError {
            return error
        }

        if case ApplePackage.ApplePackageError.licenseRequired = error {
            return AppleProtocolError(
                status: .conflict,
                message: "license required - purchase the app first",
                code: "9610"
            )
        }

        let message = (error as NSError).localizedDescription
        let code = failureCode(in: message)
        if let code {
            switch code {
            case "2034", "2042":
                return AppleProtocolError(status: .unauthorized, message: "password token is expired", code: code)
            case "5005":
                return AppleProtocolError(status: .conflict, message: "invalid or expired 2FA code", code: code)
            case "9610":
                return AppleProtocolError(
                    status: .conflict,
                    message: "license required - purchase the app first",
                    code: code
                )
            default:
                return AppleProtocolError(status: .conflict, message: message, code: code)
            }
        }

        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("rate limit") || lowercasedMessage.contains("too many requests") {
            return AppleProtocolError(status: .tooManyRequests, message: rateLimitMessage, code: rateLimitCode)
        }
        if message.contains("Authentication requires verification code") {
            return AppleProtocolError(
                status: .conflict,
                message: "Authentication requires verification code",
                codeRequired: true
            )
        }
        if lowercasedMessage.contains("password token is expired") ||
            message == "Your password has changed." ||
            lowercasedMessage.contains("expiredpasswordtoken")
        {
            return AppleProtocolError(status: .unauthorized, message: "password token is expired")
        }
        if lowercasedMessage.contains("purchasing paid apps is not supported") {
            return AppleProtocolError(status: .badRequest, message: "purchasing paid apps is not supported")
        }
        if lowercasedMessage.contains("subscription required") {
            return AppleProtocolError(status: .conflict, message: "subscription required")
        }
        if lowercasedMessage.contains("accepting terms") || lowercasedMessage.contains("termspage") {
            return AppleProtocolError(status: .conflict, message: message)
        }
        if lowercasedMessage.contains("unsupported store identifier") {
            return AppleProtocolError(status: .badRequest, message: message)
        }

        return AppleProtocolError(message: message)
    }

    private static func failureCode(in message: String) -> String? {
        guard let range = message.range(of: "failureType: ") else {
            return nil
        }

        let suffix = message[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}

/// ApplePackage keeps the device identifier in global configuration, so calls
/// are serialized here to preserve AssppWeb's per-account device identity.
private actor ApplePackageExecutor {
    func authenticate(
        email: String,
        password: String,
        code: String,
        cookies: [ApplePackage.Cookie],
        deviceIdentifier: String
    ) async throws -> ApplePackage.Account {
        ApplePackage.Configuration.deviceIdentifier = deviceIdentifier
        return try await ApplePackage.Authenticator.authenticate(
            email: email,
            password: password,
            code: code,
            cookies: cookies
        )
    }

    func purchase(
        account: ApplePackage.Account,
        app: ApplePackage.Software,
        deviceIdentifier: String
    ) async throws -> ApplePackage.Account {
        ApplePackage.Configuration.deviceIdentifier = deviceIdentifier
        var account = account
        try await ApplePackage.Purchase.purchase(account: &account, app: app)
        return account
    }

    func download(
        account: ApplePackage.Account,
        app: ApplePackage.Software,
        externalVersionId: String?,
        deviceIdentifier: String
    ) async throws -> (ApplePackage.Account, ApplePackage.DownloadOutput) {
        ApplePackage.Configuration.deviceIdentifier = deviceIdentifier
        var account = account
        let output = try await ApplePackage.Download.download(
            account: &account,
            app: app,
            externalVersionID: externalVersionId
        )
        return (account, output)
    }

    func listVersions(
        account: ApplePackage.Account,
        bundleIdentifier: String,
        deviceIdentifier: String
    ) async throws -> (ApplePackage.Account, [String]) {
        ApplePackage.Configuration.deviceIdentifier = deviceIdentifier
        var account = account
        let versions = try await ApplePackage.VersionFinder.list(
            account: &account,
            bundleIdentifier: bundleIdentifier
        )
        return (account, versions)
    }

    func versionMetadata(
        account: ApplePackage.Account,
        app: ApplePackage.Software,
        versionId: String,
        deviceIdentifier: String
    ) async throws -> (ApplePackage.Account, ApplePackage.VersionMetadata) {
        ApplePackage.Configuration.deviceIdentifier = deviceIdentifier
        var account = account
        let metadata = try await ApplePackage.VersionLookup.getVersionMetadata(
            account: &account,
            app: app,
            versionID: versionId
        )
        return (account, metadata)
    }
}

private extension AppleAccount {
    func applePackageAccount() -> ApplePackage.Account {
        ApplePackage.Account(
            email: email,
            password: password,
            appleId: appleId,
            store: normalizedStore,
            firstName: firstName,
            lastName: lastName,
            passwordToken: passwordToken,
            directoryServicesIdentifier: directoryServicesIdentifier,
            cookie: cookies.applePackageCookies(),
            pod: pod
        )
    }

    var normalizedStore: String {
        store.split(separator: "-", maxSplits: 1).first.map(String.init) ?? store
    }
}

private extension ApplePackage.Account {
    func webAccount(deviceIdentifier: String) -> AppleAccount {
        AppleAccount(
            email: email,
            password: password,
            appleId: appleId,
            store: store,
            firstName: firstName,
            lastName: lastName,
            passwordToken: passwordToken,
            directoryServicesIdentifier: directoryServicesIdentifier,
            cookies: cookie.webCookies(),
            deviceIdentifier: deviceIdentifier,
            pod: pod
        )
    }
}

private extension WebCookie {
    func applePackageCookie() -> ApplePackage.Cookie {
        ApplePackage.Cookie(
            name: name,
            value: value,
            path: path,
            domain: domain,
            expiresAt: expiresAt,
            httpOnly: httpOnly,
            secure: secure
        )
    }
}

private extension ApplePackage.Cookie {
    func webCookie() -> WebCookie {
        WebCookie(
            name: name,
            value: value,
            path: path.isEmpty ? "/" : path,
            domain: domain?.trimmingLeadingDot(),
            expiresAt: expiresAt,
            httpOnly: httpOnly,
            secure: secure
        )
    }
}

private extension Array where Element == WebCookie {
    func applePackageCookies() -> [ApplePackage.Cookie] {
        map { $0.applePackageCookie() }
    }
}

private extension Array where Element == ApplePackage.Cookie {
    func webCookies() -> [WebCookie] {
        map { $0.webCookie() }
    }
}

private extension Software {
    func applePackageSoftware() -> ApplePackage.Software {
        var software = ApplePackage.Software(
            id: id,
            bundleID: bundleID,
            name: name,
            version: version,
            price: price,
            artistName: artistName,
            sellerName: sellerName,
            description: description,
            averageUserRating: averageUserRating,
            userRatingCount: Int(userRatingCount),
            artworkUrl: artworkUrl,
            screenshotUrls: screenshotUrls,
            minimumOsVersion: minimumOsVersion,
            fileSizeBytes: fileSizeBytes,
            releaseDate: releaseDate,
            formattedPrice: formattedPrice,
            primaryGenreName: primaryGenreName
        )
        software.releaseNotes = releaseNotes
        return software
    }
}

private extension ApplePackage.DownloadOutput {
    func webDownloadOutput() -> AppleDownloadOutput {
        AppleDownloadOutput(
            downloadURL: downloadURL,
            sinfs: sinfs.map { Sinf(id: $0.id, sinf: $0.sinf.base64EncodedString()) },
            bundleShortVersionString: bundleShortVersionString,
            bundleVersion: bundleVersion,
            iTunesMetadata: iTunesMetadata.base64EncodedString()
        )
    }
}

private extension ApplePackage.VersionMetadata {
    func webVersionMetadata() -> VersionMetadata {
        VersionMetadata(
            displayVersion: displayVersion,
            releaseDate: ISO8601DateFormatter().string(from: releaseDate)
        )
    }
}

private extension String {
    func trimmingLeadingDot() -> String {
        hasPrefix(".") ? String(dropFirst()) : self
    }
}
