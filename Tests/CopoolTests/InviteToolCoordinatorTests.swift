import XCTest
@testable import Copool

final class InviteToolCoordinatorTests: XCTestCase {
    func testBatchParserAcceptsCommaTabAndWhitespaceFormats() {
        let entries = InviteToolBatchParser.parseLines(
            """
            # comment
            Z-ONE,user1@example.com
            Z-TWO\tuser2@example.com
            Z-THREE user3@example.com
            Z-FOUR
            """
        )

        XCTAssertEqual(
            entries,
            [
                InviteToolInputLine(lineNumber: 2, code: "Z-ONE", email: "user1@example.com"),
                InviteToolInputLine(lineNumber: 3, code: "Z-TWO", email: "user2@example.com"),
                InviteToolInputLine(lineNumber: 4, code: "Z-THREE", email: "user3@example.com"),
                InviteToolInputLine(lineNumber: 5, code: "Z-FOUR", email: nil),
            ]
        )
    }

    func testRedeemReturnsClientErrorWhenEmailMissing() async {
        let coordinator = InviteToolCoordinator(service: StubInviteToolService())
        let rows = await coordinator.run(
            operation: .redeem,
            entries: [InviteToolInputLine(lineNumber: 1, code: "Z-ONE", email: nil)],
            defaultEmail: nil
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tone, .error)
        XCTAssertEqual(rows[0].step, .validateInput)
        XCTAssertTrue(rows[0].message.contains("邮箱"))
    }

    func testWarrantyReactivationFallsBackToLastUsedEmail() async {
        let service = StubInviteToolService()
        service.warrantyPayload = InviteToolResponsePayload(
            code: "Z-ONE",
            email: nil,
            invitedAt: nil,
            codeTypeDisplay: nil,
            warrantyDuration: 30,
            firstUsedAt: nil,
            warrantyExpiresAt: nil,
            isWarranty: nil,
            message: "需要重新激活",
            level: "warning",
            reason: "reactivation_required",
            status: nil,
            statusLabel: nil,
            statusLevel: nil,
            lastUsedEmail: "last@example.com",
            usedByEmail: nil,
            usedAt: nil
        )
        service.warrantyRedeemPayload = InviteToolResponsePayload(
            code: "Z-ONE",
            email: "last@example.com",
            invitedAt: "2026-03-18 12:00:00",
            codeTypeDisplay: nil,
            warrantyDuration: 30,
            firstUsedAt: nil,
            warrantyExpiresAt: nil,
            isWarranty: nil,
            message: "已重新激活",
            level: "success",
            reason: nil,
            status: nil,
            statusLabel: nil,
            statusLevel: nil,
            lastUsedEmail: "last@example.com",
            usedByEmail: nil,
            usedAt: nil
        )

        let coordinator = InviteToolCoordinator(service: service, requestDelay: .zero)
        let rows = await coordinator.run(
            operation: .warranty,
            entries: [InviteToolInputLine(lineNumber: 1, code: "Z-ONE", email: nil)],
            defaultEmail: nil
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].step, .warrantyRedeem)
        XCTAssertEqual(rows[0].finalEmail, "last@example.com")
        XCTAssertEqual(service.lastWarrantyRedeemEmail, "last@example.com")
        XCTAssertEqual(service.lastWarrantyRedeemOriginalEmail, "last@example.com")
    }

    func testResultDetailsDoNotExposeLineNumber() {
        let row = InviteToolResultRow(
            lineNumber: 3,
            code: "Z-ONE",
            tone: .success,
            step: .status,
            message: "已使用",
            requestEmail: nil,
            finalEmail: nil,
            payload: InviteToolResponsePayload(
                code: "Z-ONE",
                email: nil,
                invitedAt: nil,
                codeTypeDisplay: nil,
                warrantyDuration: nil,
                firstUsedAt: nil,
                warrantyExpiresAt: nil,
                isWarranty: nil,
                message: nil,
                level: nil,
                reason: nil,
                status: "used",
                statusLabel: "已使用",
                statusLevel: "success",
                lastUsedEmail: nil,
                usedByEmail: "user@example.com",
                usedAt: nil
            )
        )

        XCTAssertFalse(row.detailItems.contains(where: { $0.0 == "行号" }))
    }
}

private final class StubInviteToolService: InviteToolServiceProtocol, @unchecked Sendable {
    var redeemPayload = InviteToolResponsePayload(
        code: "Z-DEFAULT",
        email: "user@example.com",
        invitedAt: "2026-03-18 12:00:00",
        codeTypeDisplay: nil,
        warrantyDuration: 30,
        firstUsedAt: nil,
        warrantyExpiresAt: nil,
        isWarranty: nil,
        message: "兑换成功",
        level: "success",
        reason: nil,
        status: nil,
        statusLabel: nil,
        statusLevel: nil,
        lastUsedEmail: nil,
        usedByEmail: nil,
        usedAt: nil
    )
    var warrantyPayload = InviteToolResponsePayload(
        code: "Z-DEFAULT",
        email: nil,
        invitedAt: nil,
        codeTypeDisplay: nil,
        warrantyDuration: 30,
        firstUsedAt: nil,
        warrantyExpiresAt: nil,
        isWarranty: nil,
        message: "对应车位仍可用，无需重置。",
        level: "success",
        reason: "spot_active",
        status: "used",
        statusLabel: nil,
        statusLevel: nil,
        lastUsedEmail: "old@example.com",
        usedByEmail: nil,
        usedAt: nil
    )
    var warrantyRedeemPayload = InviteToolResponsePayload(
        code: "Z-DEFAULT",
        email: "old@example.com",
        invitedAt: "2026-03-18 12:00:00",
        codeTypeDisplay: nil,
        warrantyDuration: 30,
        firstUsedAt: nil,
        warrantyExpiresAt: nil,
        isWarranty: nil,
        message: "已重新激活",
        level: "success",
        reason: nil,
        status: nil,
        statusLabel: nil,
        statusLevel: nil,
        lastUsedEmail: "old@example.com",
        usedByEmail: nil,
        usedAt: nil
    )
    var statusPayload = InviteToolResponsePayload(
        code: "Z-DEFAULT",
        email: nil,
        invitedAt: nil,
        codeTypeDisplay: nil,
        warrantyDuration: 30,
        firstUsedAt: nil,
        warrantyExpiresAt: nil,
        isWarranty: nil,
        message: nil,
        level: nil,
        reason: nil,
        status: "used",
        statusLabel: "已使用",
        statusLevel: "success",
        lastUsedEmail: nil,
        usedByEmail: "user@example.com",
        usedAt: "2026-03-18 12:00:00"
    )

    private(set) var lastWarrantyRedeemEmail: String?
    private(set) var lastWarrantyRedeemOriginalEmail: String?

    func redeem(code: String, email: String) async throws -> InviteToolResponsePayload {
        _ = code
        var payload = redeemPayload
        payload.email = email
        return payload
    }

    func checkWarranty(code: String) async throws -> InviteToolResponsePayload {
        _ = code
        return warrantyPayload
    }

    func redeemWarranty(code: String, email: String, lastUsedEmail: String) async throws -> InviteToolResponsePayload {
        _ = code
        lastWarrantyRedeemEmail = email
        lastWarrantyRedeemOriginalEmail = lastUsedEmail
        var payload = warrantyRedeemPayload
        payload.email = email
        payload.lastUsedEmail = lastUsedEmail
        return payload
    }

    func queryStatus(code: String) async throws -> InviteToolResponsePayload {
        _ = code
        return statusPayload
    }
}
