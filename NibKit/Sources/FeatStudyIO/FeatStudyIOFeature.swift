import NibContracts

/// F051 Study set import & export: CSV / TSV / TXT importers (Quizlet exports, Anki "Notes in Plain Text") that create
/// study sets, the "study.csv" exporter, and the `study.importText` / `study.exportCSV` commands.
public enum FeatStudyIOFeature: NibFeature {
    public static let id = "studyio"

    public static func register(_ app: NibApp) {
        app.commands.register(StudyImportText.self)
        app.commands.register(StudyExportCSV.self)
        for format in StudyTextFormat.allCases {
            app.content.importers.register(StudyImport.importer(format, owner: id))
        }
        app.content.exporters.register(StudyExport.exporter(owner: id))
    }
}
