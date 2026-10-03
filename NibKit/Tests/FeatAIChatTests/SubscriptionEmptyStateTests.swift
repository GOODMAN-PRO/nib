import XCTest
@testable import FeatAIChat

@MainActor
final class SubscriptionEmptyStateTests: XCTestCase {
    func testEmptyStateLeadsWithBothSubscriptionsAndKeepsOtherProviders() {
        XCTAssertEqual(ChatViewModel.connectionPage(for: ChatViewModel.connectionActions[0]), "settings.ai.claude")
        XCTAssertEqual(ChatViewModel.connectionPage(for: ChatViewModel.connectionActions[1]), "settings.ai.chatgpt")
        XCTAssertEqual(ChatViewModel.connectionPage(for: ChatViewModel.connectionActions[2]), "settings.ai")
        XCTAssertEqual(ChatViewModel.connectionActions, ["Use my Claude subscription", "Use my ChatGPT subscription", "Other providers"])
    }
}
