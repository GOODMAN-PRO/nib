import Foundation
import NibContracts

/// F084: the AI agent. Installs `services.ai` (`AgentService`): the tool catalogue of AI.md §4 (nine meta-tools plus
/// configurable direct tools, built with NibContracts' `ToolCatalog` like the bridge), the system prompt of §5, the
/// agent loop (one undo group and one principal per turn, errors returned to the model, 20 KB paging, step limit,
/// cancel, vision through `render.page`), per-device conversation files merged by message id, and the `ai.ask` /
/// `ai.chat.*` commands. Sets the AI's confirmation policy from `security.ai.confirmationPolicy`.
public enum NibAIAgentFeature: NibFeature {
    public static let id = "aiagent"

    public static func register(_ app: NibApp) {
        app.settings.declare(AgentSettings.directTools,
                             summary: "Commands the AI gets as their own tools besides the meta-tools (command ids).",
                             owner: id, schema: .arr(.str("command id, e.g. 'page.add'")))
        // Match F086's declaration so either feature registration order uses the same routing and validation.
        app.settings.declare(AgentSettings.maxSteps, summary: "Maximum tool rounds in an AI turn.",
                             owner: id, schema: .int(min: 1, max: 100))
        let settings = app.settings
        app.gateway.setPolicy(forPrincipalKind: "ai") { [weak settings] _ in
            settings?.get(NibSettings.aiConfirmationPolicy) ?? .destructive
        }
        app.services.ai = AgentService(app: app)
        ChatCommands.register(app.commands)
    }
}
