import Foundation

enum MarkdownExport {
    static func summary(of meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", "_\(meeting.createdAt.formatted(date: .long, time: .shortened)) · \(meeting.duration.clock)_", ""]
        guard let a = meeting.analysis else { return lines.joined(separator: "\n") }
        lines += ["## Resumo", a.summary, ""]
        if !a.decisions.isEmpty {
            lines.append("## Decisões")
            lines += a.decisions.map { "- \($0.decision)\($0.owner.map { " — \($0)" } ?? "")" }
            lines.append("")
        }
        if !a.actionItems.isEmpty {
            lines.append("## Tarefas")
            lines += a.actionItems.map(task)
            lines.append("")
        }
        if !a.openQuestions.isEmpty {
            lines.append("## Em aberto")
            for q in a.openQuestions {
                lines.append("- **\(q.question)**")
                if let r = q.recommendation { lines.append("  - Recomendação: \(r)") }
            }
            lines.append("")
        }
        if !a.nextAgenda.isEmpty {
            lines.append("## Próxima pauta")
            lines += a.nextAgenda.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    static func tasks(of meeting: Meeting) -> String {
        (meeting.analysis?.actionItems ?? []).map(task).joined(separator: "\n")
    }

    private static func task(_ item: MeetingAnalysis.ActionItem) -> String {
        var line = "- [\(item.done ? "x" : " ")] \(item.title)"
        if let owner = item.owner { line += " — @\(owner)" }
        if let due = item.dueDate { line += " (até \(due))" }
        return line
    }
}
