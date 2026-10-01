import SwiftUI
import NibContracts
import NibDesign

struct SmartLearnView: View {
    @ObservedObject var model: StudySessionModel
    let close: () -> Void
    var body: some View { StudySessionView(model: model, smartLearn: true, close: close) }
}

struct StudySummaryView: View {
    @ObservedObject var model: StudySessionModel
    let smartLearn: Bool
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: NibSpacing.l) {
            Text(model.liveCards.isEmpty ? String(localized: "No cards yet") : String(localized: "Review complete"))
                .font(NibFont.emptyTitle)
            if model.liveCards.isEmpty {
                Text(String(localized: "Add cards in the study set editor to begin."))
            } else if smartLearn {
                Text(String(localized: "Reviewed: \(model.reviewed.count)"))
                Text(String(localized: "Due tomorrow: \(dueTomorrow)"))
                if let next = model.nextReview {
                    Text(String(localized: "Next review: \(Date(timeIntervalSince1970: max(next, model.runtime.now())).formatted(date: .abbreviated, time: .shortened))"))
                }
                if !model.hardest.isEmpty {
                    Text(String(localized: "Hardest cards")).font(NibFont.headline)
                    ForEach(model.hardest, id: \.self) { id in
                        if let card = model.cardsByID[id] {
                            Text(card.front.text?.plainText ?? String(localized: "Handwritten or image card"))
                        }
                    }
                }
            }
            NibButton(String(localized: "Return to Study Set"), symbol: .back, kind: .plain) { model.end(close: close) }
        }
        .font(NibFont.body)
        .frame(maxWidth: NibMetrics.studyCardSize.width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
    private var dueTomorrow: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: model.runtime.now()))
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: tomorrow) else { return 0 }
        return model.liveCards.filter {
            let due = Scheduler.dueDate($0)
            return due >= tomorrow.timeIntervalSince1970 && due < end.timeIntervalSince1970
        }.count
    }
}
