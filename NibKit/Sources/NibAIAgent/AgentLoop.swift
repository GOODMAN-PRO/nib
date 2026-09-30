import Foundation
import NibContracts

/// What a turn produced, finished or not.
struct TurnOutcome {
    /// Everything the model wrote this turn (rounds separated by a blank line).
    var text = ""
    /// The last round's text (the answer of a JSON-only request).
    var finalText = ""
    var changes = ChangeSummary()
    var usage = AIUsage()
    /// Tool rounds run.
    var steps = 0
    var toolNames: [String] = []
    var cancelled = false
    var stepLimitReached = false
    var error: NibError?
}

/// One turn of the agent (AI.md §1): stream the provider, run the tool calls it asks for through the bus (as the
/// turn's principal, in the turn's undo group, read-only in Ask mode), feed the results back, and repeat until the
/// model answers, `maxSteps` tool rounds ran, or the turn is cancelled.
@MainActor
final class AgentLoop {
    struct Setup {
        var provider: AIProvider
        var config: AIProviderConfig
        /// The conversation sent to the model (stored history + the new messages).
        var history: [ChatMessage]
        var mode: AIMode
        var readOnly: Bool
        var scope: AIScope?
        var system: String?
        var jsonOutput: Bool
        var maxSteps: Int
        var principal: Principal
        var group: String
        var session: EditorSession?
        var depth: Int
        var inheritedPolicy: ConfirmationPolicy?
        var toolbox: AgentToolbox
        var toolTimeout: TimeInterval
        var contextTimeout: TimeInterval
    }

    /// Last text part of the final round when the step limit is reached.
    static func stepLimitNote(_ steps: Int) -> String {
        "You have used the limit of \(steps) tool steps for this turn. Do not call more tools: answer now, saying what you did and what is left."
    }

    let bus: CommandBus
    let pluginHost: PluginHosting?
    let setup: Setup

    init(bus: CommandBus, pluginHost: PluginHosting?, setup: Setup) {
        self.bus = bus
        self.pluginHost = pluginHost
        self.setup = setup
    }

    /// The system prompt of this turn: static part + U+001E + dynamic part.
    func systemPrompt() async -> String {
        let s = setup
        let staticPart = SystemPrompt.staticPart(registry: bus.registry, exposure: s.principal.exposure,
                                                 pluginInstructions: pluginHost?.aiInstructions ?? [])
        let gathered = await SystemPrompt.gather(bus: bus, workspace: bus.workspace, gateway: bus.gateway,
                                                 principal: s.principal, group: s.group, session: s.session,
                                                 depth: s.depth, scope: s.scope, timeout: s.contextTimeout)
        let dynamic = SystemPrompt.Dynamic(mode: s.mode, readOnly: s.readOnly, toolsAvailable: !s.toolbox.isEmpty,
                                           context: gathered.context, scope: s.scope, pageRef: gathered.pageRef,
                                           pageText: gathered.pageText, pageTextTooLong: gathered.tooLong,
                                           language: gathered.language, extra: s.system, jsonOutput: s.jsonOutput)
        return SystemPrompt.compose(staticPart: staticPart, dynamicPart: SystemPrompt.dynamicPart(dynamic))
    }

    func run(_ sink: @escaping @MainActor (AIStreamEvent) -> Void) async -> TurnOutcome {
        var out = TurnOutcome()
        let s = setup
        let system = await systemPrompt()
        if Task.isCancelled {
            out.cancelled = true
            return out
        }
        let runner = AgentToolRunner(
            bus: bus, toolbox: s.toolbox,
            setup: AgentToolRunner.Setup(principal: s.principal, group: s.group, readOnly: s.readOnly, session: s.session,
                                         depth: s.depth, inheritedPolicy: s.inheritedPolicy,
                                         vision: s.config.supportsVision, timeout: s.toolTimeout))
        var messages = s.history
        let maxSteps = max(1, s.maxSteps)
        var callSeq = 0

        while true {
            let request = ChatRequest(model: s.config.model, system: system, messages: messages, tools: s.toolbox.tools,
                                      maxTokens: s.config.maxOutputTokens)
            var roundText = ""
            var calls: [(id: String, name: String, arguments: JSONValue)] = []
            do {
                for try await event in s.provider.stream(request) {
                    switch event {
                    case .textDelta(let delta):
                        guard !delta.isEmpty else { continue }
                        if roundText.isEmpty && !out.text.isEmpty && !out.text.hasSuffix("\n") {
                            out.text += "\n\n"
                            sink(.text("\n\n"))
                        }
                        roundText += delta
                        out.text += delta
                        sink(.text(delta))
                    case let .toolCall(id, name, arguments):
                        callSeq += 1
                        calls.append((id.isEmpty ? "call_\(callSeq)" : id, name, arguments))
                    case let .usage(input, output):
                        out.usage.input += input
                        out.usage.output += output
                    case .stop:
                        break
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    out.cancelled = true
                } else {
                    out.error = NibError.wrap(error)
                }
                out.finalText = roundText
                return out
            }
            out.finalText = roundText
            if Task.isCancelled {
                out.cancelled = true
                return out
            }
            guard !calls.isEmpty else { return out }
            guard out.steps < maxSteps else {
                // The model ignored the step-limit note: stop without running more tools.
                out.stepLimitReached = true
                let note = "(Stopped after \(maxSteps) tool steps.)"
                out.text += out.text.isEmpty ? note : "\n\n" + note
                sink(.text(out.text == note ? note : "\n\n" + note))
                return out
            }
            out.steps += 1

            var assistant: [ChatPart] = roundText.isEmpty ? [] : [.text(roundText)]
            assistant += calls.map { .toolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
            messages.append(ChatMessage(role: .assistant, parts: assistant))

            var results: [ChatPart] = []
            for call in calls {
                if Task.isCancelled {
                    let e = NibError(.userDenied, "the user stopped the turn before this call ran")
                    results.append(.toolResult(id: call.id, parts: [.text(e.json.jsonString())], isError: true))
                    continue
                }
                sink(.toolStarted(name: call.name, arguments: call.arguments))
                let outcome = await runner.run(name: call.name, arguments: call.arguments)
                out.changes.merge(outcome.changes)
                out.toolNames.append(call.name)
                sink(.toolFinished(name: call.name, ok: !outcome.isError, changes: outcome.changes.isEmpty ? nil : outcome.changes))
                results.append(.toolResult(id: call.id, parts: outcome.parts, isError: outcome.isError))
            }
            if out.steps == maxSteps { results.append(.text(AgentLoop.stepLimitNote(maxSteps))) }
            messages.append(ChatMessage(role: .tool, parts: results))
            if Task.isCancelled {
                out.cancelled = true
                return out
            }
        }
    }

    /// A JSON-only answer without the code fence many models wrap it in.
    static func unfenced(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let firstLineEnd = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstLineEnd)...]) } else { return t }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
