import XCTest
@testable import Copool

final class PastedRefreshTokenAccountParserTests: XCTestCase {
    func testParseAcceptsLineWithIgnoredMiddleSegments() throws {
        let input = "user@example.com----password----note----rt_token_123"

        let result = try PastedRefreshTokenAccountParser.parse(input)

        XCTAssertEqual(
            result,
            [
                PastedRefreshTokenAccountRecord(
                    email: "user@example.com",
                    refreshToken: "rt_token_123"
                )
            ]
        )
    }

    func testParseAcceptsLineWithoutMiddleSegments() throws {
        let input = "user@example.com----rt_token_123"

        let result = try PastedRefreshTokenAccountParser.parse(input)

        XCTAssertEqual(
            result,
            [
                PastedRefreshTokenAccountRecord(
                    email: "user@example.com",
                    refreshToken: "rt_token_123"
                )
            ]
        )
    }

    func testParseSkipsBlankLines() throws {
        let input = """

        user@example.com----password----rt_token_123

        second@example.com----rt_token_456

        """

        let result = try PastedRefreshTokenAccountParser.parse(input)

        XCTAssertEqual(
            result,
            [
                PastedRefreshTokenAccountRecord(
                    email: "user@example.com",
                    refreshToken: "rt_token_123"
                ),
                PastedRefreshTokenAccountRecord(
                    email: "second@example.com",
                    refreshToken: "rt_token_456"
                )
            ]
        )
    }

    func testParseRejectsInvalidEmail() {
        XCTAssertThrowsError(
            try PastedRefreshTokenAccountParser.parse("not-an-email----password----rt_token_123")
        ) { error in
            XCTAssertEqual(
                error as? PastedRefreshTokenAccountParser.ParseError,
                .invalidEmail(line: 1)
            )
        }
    }

    func testParseRejectsMissingRefreshTokenAtLastSegment() {
        XCTAssertThrowsError(
            try PastedRefreshTokenAccountParser.parse("user@example.com----password----not_rt")
        ) { error in
            XCTAssertEqual(
                error as? PastedRefreshTokenAccountParser.ParseError,
                .invalidRefreshToken(line: 1)
            )
        }
    }
}
