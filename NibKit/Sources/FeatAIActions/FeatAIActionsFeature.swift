import NibContracts

public enum FeatAIActionsFeature: NibFeature {
    public static let id = "aiactions"

    public static func register(_ app: NibApp) {
        AIActionCommands.register(app.commands)
        BuiltinActions.register(app)
        app.settings.declarePrefix(UserActions.prefix, synced: true,
            summary: "One user AI quick action per key; set null to remove it.", owner: id,
            schema: UserActions.schema)
    }

    public static func start(_ app: NibApp) async {
        let actions = UserActions(app: app)
        app.services.set(actions, for: UserActions.serviceKey)
        actions.refresh()
    }
}
