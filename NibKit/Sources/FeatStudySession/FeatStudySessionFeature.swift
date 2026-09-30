import Foundation
import SwiftUI
import NibContracts
import NibDesign

public enum FeatStudySessionFeature: NibFeature {
    public static let id = "studysession"
    public static func register(_ app: NibApp) {
        app.services.set(StudyRuntime(), for: StudyRuntime.serviceKey)
        app.commands.register(StudyGrade.self)
        app.commands.register(StudyResetProgress.self)
        app.commands.register(StudySetReminders.self)
        app.commands.register(StudySetTheme.self)
        app.commands.register(StudyQuery.self)
        app.commands.register(StudySessionAction.self)
        app.commands.register(StudyRequestReminders.self)
        for (panel, learn) in [(PanelIDs.studyPractice, false), (PanelIDs.studySmartLearn, true)] {
            var descriptor = PanelDescriptor(id: panel, title: learn ? String(localized: "Smart Learn") : String(localized: "Practice"),
                icon: NibSymbol.studySets.name, placement: .sheet, order: learn ? 510 : 500, owner: id, docKinds: [.studySet]) { context in
                guard let runtime = context.app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self),
                      let doc = context.params["doc"]?.stringValue.map(NodeRef.documentID(from:)) ?? context.session?.document else {
                    return AnyView(NibEmptyState(symbol: .studySets, title: String(localized: "Open a study set")))
                }
                let model = runtime.model(app: context.app, doc: doc, session: context.session ?? context.app.services.sessions.active)
                if learn { return AnyView(SmartLearnView(model: model, close: context.dismiss)) }
                return AnyView(PracticeView(model: model, close: context.dismiss))
            }
            descriptor.providesHeader = true
            app.ui.panels.register(descriptor)
        }
        for (key, action, title) in [("left", "previous", String(localized: "Previous Card")),
                                     ("right", "next", String(localized: "Next Card")),
                                     ("space", "flip", String(localized: "Flip Card"))] {
            var descriptor = KeyCommandDescriptor(id: "studysession.key." + action, title: title, shortcut: KeyShortcut(key),
                command: StudySessionAction.id, params: ["action": .string(action), "instant": true], scope: .canvas, order: 500, owner: id)
            descriptor.docKinds = [.studySet]
            descriptor.sessionParams = { session in
                guard let doc = session.document else { return [:] }
                return ["doc": .string(NodeRef.document(doc).description)]
            }
            app.content.keyCommands.register(descriptor)
        }
        for (index, rating) in StudyRating.allCases.enumerated() {
            var descriptor = KeyCommandDescriptor(id: "studysession.key." + rating.rawValue, title: rating.title,
                shortcut: KeyShortcut(String(index + 1)), command: StudySessionAction.id,
                params: ["action": "grade", "rating": .string(rating.rawValue), "instant": true],
                scope: .canvas, order: 500, owner: id)
            descriptor.docKinds = [.studySet]
            descriptor.sessionParams = { session in
                guard let doc = session.document else { return [:] }
                return ["doc": .string(NodeRef.document(doc).description)]
            }
            app.content.keyCommands.register(descriptor)
        }
    }
    public static func start(_ app: NibApp) async {
        app.services.get(StudyRuntime.serviceKey, as: StudyRuntime.self)?.start(app)
    }
}
