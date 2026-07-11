import SwiftUI

private enum QuestionnaireCrownMode: String {
    case question = "Questions"
    case option = "Answers"
}

struct PlanQuestionnaireView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CodexWatchStore

    let questionnaire: WatchQuestionnaire

    @State private var selectedQuestionIndex = 0
    @State private var highlightedOptionIndex = 0
    @State private var crownQuestionValue = 0.0
    @State private var crownOptionValue = 0.0
    @State private var crownMode: QuestionnaireCrownMode = .question
    @State private var answers: [String: [String]] = [:]
    @State private var isSubmitting = false

    private var currentQuestion: WatchQuestion {
        questionnaire.questions[selectedQuestionIndex]
    }

    private var optionLabels: [String] {
        let base = currentQuestion.options.map(\.label)
        return currentQuestion.supportsOtherVoice ? base + ["Other"] : base
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                questionCard
                answerSummary
                optionList
                footerControls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .focusable(true)
        .digitalCrownRotation(
            crownMode == .question ? $crownQuestionValue : $crownOptionValue,
            from: 0,
            through: crownMode == .question ? Double(max(questionnaire.questions.count - 1, 0)) : Double(max(optionLabels.count - 1, 0)),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownQuestionValue) { newValue in
            let clamped = Int(newValue.rounded())
            guard questionnaire.questions.indices.contains(clamped) else { return }
            selectedQuestionIndex = clamped
            syncHighlightedOption()
        }
        .onChange(of: crownOptionValue) { newValue in
            let clamped = Int(newValue.rounded())
            guard optionLabels.indices.contains(clamped) else { return }
            highlightedOptionIndex = clamped
        }
        .background(Color.black)
        .navigationTitle("Plan Mode")
        .task {
            syncHighlightedOption()
        }
    }

    private var questionCard: some View {
        CodexCard(
            title: "\(selectedQuestionIndex + 1) of \(questionnaire.questions.count)",
            subtitle: "Crown: \(crownMode.rawValue)"
        ) {
            Text(currentQuestion.header)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(currentQuestion.question)
                .foregroundStyle(.white)
        }
        .onTapGesture {
            crownMode = .option
        }
    }

    @ViewBuilder
    private var answerSummary: some View {
        if !answers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Answers")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))

                ForEach(questionnaire.questions, id: \.id) { question in
                    if let response = answers[question.id]?.first {
                        HStack {
                            FolderChip(label: question.header)
                            Text(response)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(optionLabels.enumerated()), id: \.offset) { index, option in
                Button {
                    Task {
                        await selectOption(option, at: index)
                    }
                } label: {
                    optionRow(option, at: index)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func optionRow(_ option: String, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(option)
                    .foregroundStyle(.white)
                Spacer()
                if answers[currentQuestion.id]?.first == option {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let description = descriptionForOption(named: option) {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(highlightedOptionIndex == index ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
        )
    }

    private var footerControls: some View {
        HStack {
            Button(crownMode == .question ? "Focus Answers" : "Focus Questions") {
                crownMode = crownMode == .question ? .option : .question
            }
            .font(.caption2)

            Spacer()

            Button(isSubmitting ? "Sending..." : "Submit") {
                Task {
                    await submit()
                }
            }
            .disabled(answers.count < questionnaire.questions.count || isSubmitting)
        }
    }

    private func descriptionForOption(named label: String) -> String? {
        currentQuestion.options.first(where: { $0.label == label })?.description
    }

    private func syncHighlightedOption() {
        if let existing = answers[currentQuestion.id]?.first, let index = optionLabels.firstIndex(of: existing) {
            highlightedOptionIndex = index
            crownOptionValue = Double(index)
            return
        }
        highlightedOptionIndex = 0
        crownOptionValue = 0
    }

    private func selectOption(_ option: String, at index: Int) async {
        highlightedOptionIndex = index
        crownOptionValue = Double(index)

        if option == "Other" {
            await captureOtherAnswer()
        } else {
            answers[currentQuestion.id] = [option]
            advanceQuestionIfPossible()
        }
    }

    private func captureOtherAnswer() async {
        do {
            let dictated = try await DictationService.requestTextInput(suggestions: ["Use a different folder", "Keep current repo"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dictated.isEmpty else { return }
            answers[currentQuestion.id] = [dictated]
            advanceQuestionIfPossible()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func advanceQuestionIfPossible() {
        guard selectedQuestionIndex < questionnaire.questions.count - 1 else { return }
        selectedQuestionIndex += 1
        crownQuestionValue = Double(selectedQuestionIndex)
        crownMode = .question
        syncHighlightedOption()
    }

    private func submit() async {
        guard answers.count == questionnaire.questions.count else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        await store.answer(questionnaire: questionnaire, answers: answers)
        dismiss()
    }
}
