import Foundation
@testable import UnfairDaemonCore
import Vapor
import XCTest

final class AppleProtocolServiceTests: XCTestCase {
    func testApplePackageRateLimitErrorMapsToProtocolError() {
        let source = NSError(
            domain: "ApplePackage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Rate limit exceeded"]
        )

        let error = AppleProtocolService.protocolErrorForTesting(source)

        XCTAssertEqual(error.status, .tooManyRequests)
        XCTAssertEqual(error.code, "rate_limited")
        XCTAssertEqual(error.message, "Apple rate limit reached. Wait before trying again.")
    }

    func testApplePackageVerificationErrorMapsToCodeRequired() {
        let source = NSError(
            domain: "ApplePackage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Authentication requires verification code\nOpen Apple account settings."]
        )

        let error = AppleProtocolService.protocolErrorForTesting(source)

        XCTAssertEqual(error.status, .conflict)
        XCTAssertEqual(error.message, "Authentication requires verification code")
        XCTAssertTrue(error.codeRequired)
    }

    func testPasswordTokenExpiredErrorDetection() {
        let expiredBy2034 = AppleProtocolError(status: .unauthorized, message: "password token is expired", code: "2034")
        let expiredBy2042 = AppleProtocolError(status: .unauthorized, message: "password token is expired", code: "2042")
        let expiredByMessage = AppleProtocolError(status: .unauthorized, message: "password token is expired", code: "5002")
        let otherError = AppleProtocolError(status: .conflict, message: "purchase failed", code: "5002")

        XCTAssertTrue(expiredBy2034.isPasswordTokenExpired)
        XCTAssertTrue(expiredBy2042.isPasswordTokenExpired)
        XCTAssertTrue(expiredByMessage.isPasswordTokenExpired)
        XCTAssertFalse(otherError.isPasswordTokenExpired)
    }
}
