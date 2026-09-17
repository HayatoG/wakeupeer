import AppKit
import Charts
import SwiftUI
import WakeUpeerDomain
import WakeUpeerPlatformMac

/// Relatório semanal de uso.
struct ReportView: View {
    let state: AppState

    /// Quantas semanas atrás estamos olhando. 0 é a semana corrente.
    @State private var weekOffset = 0

    private var referenceDate: Date {
        Calendar.current.date(byAdding: .weekOfYear, value: -weekOffset, to: Date()) ?? Date()
    }

    private var report: UsageReport {
        state.report(forWeekContaining: referenceDate)
    }

    var body: some View {
        let report = self.report

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WeekPicker(offset: $weekOffset, report: report)

                if report.totalActive == 0 {
                    EmptyWeek(isCurrentWeek: weekOffset == 0)
                } else {
                    SummaryRow(report: report)
                    DailyChart(report: report, profiles: state.config.profiles)
                    TopAppsChart(report: report)
                    ProfileBreakdown(report: report, profiles: state.config.profiles)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    export(report)
                } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(report.totalActive == 0)
            }
        }
    }

    private func export(_ report: UsageReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wakeupeer-uso.csv"
        panel.allowedContentTypes = [.commaSeparatedText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var csv = "app,bundle_id,segundos,horas\n"
        for app in report.apps {
            let name = app.appName.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(name)\",\(app.bundleID),\(Int(app.total)),"
            csv += String(format: "%.2f\n", app.total / 3600)
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Seletor de semana

private struct WeekPicker: View {
    @Binding var offset: Int
    let report: UsageReport

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                Text(rangeLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 2) {
                Button {
                    offset += 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Semana anterior")

                Button {
                    offset -= 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(offset == 0)
                .help("Próxima semana")
            }
            .buttonStyle(.bordered)

            if offset != 0 {
                Button("Hoje") { offset = 0 }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var title: String {
        switch offset {
        case 0: "Esta semana"
        case 1: "Semana passada"
        default: "\(offset) semanas atrás"
        }
    }

    private var rangeLabel: String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d 'de' MMMM"
        // O fim do intervalo é exclusivo; mostra o último dia de fato.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: report.end) ?? report.end
        return "\(formatter.string(from: report.start)) – \(formatter.string(from: lastDay))"
    }
}

// MARK: - Resumo

private struct SummaryRow: View {
    let report: UsageReport

    var body: some View {
        HStack(spacing: 12) {
            SummaryCard(
                label: "Tempo ativo",
                value: DurationFormat.short(report.totalActive),
                symbol: "clock.fill",
                tint: .blue)

            SummaryCard(
                label: "Média diária",
                value: DurationFormat.short(report.dailyAverage),
                symbol: "calendar",
                tint: .purple)

            if let busiest = report.busiestDay {
                SummaryCard(
                    label: "Dia mais cheio",
                    value: weekdayName(busiest.date),
                    detail: DurationFormat.short(busiest.active),
                    symbol: "flame.fill",
                    tint: .orange)
            }

            if let top = report.apps.first {
                SummaryCard(
                    label: "App campeão",
                    value: top.appName,
                    detail: DurationFormat.short(top.total),
                    symbol: "trophy.fill",
                    tint: .green)
            }
        }
    }

    private func weekdayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date).capitalized
    }
}

private struct SummaryCard: View {
    let label: String
    let value: String
    var detail: String? = nil
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: - Gráfico por dia

private struct DailyChart: View {
    let report: UsageReport
    let profiles: [Profile]

    /// Uma barra por dia, empilhada por perfil.
    private struct Segment: Identifiable {
        var id: String { "\(day)-\(profileName)" }
        var day: String
        var date: Date
        var profileName: String
        var hours: Double
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for day in report.days {
            var accounted: TimeInterval = 0
            for (profileID, total) in day.perProfile {
                let name = profiles.first { $0.id == profileID }?.name ?? "Outro"
                result.append(
                    Segment(
                        day: day.day, date: day.date, profileName: name,
                        hours: total / 3600))
                accounted += total
            }
            // O tempo fora de qualquer perfil também precisa aparecer.
            let unassigned = day.active - accounted
            if unassigned > 60 {
                result.append(
                    Segment(
                        day: day.day, date: day.date, profileName: "Sem perfil",
                        hours: unassigned / 3600))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Tempo por dia", detail: "empilhado por perfil")

            Chart(segments) { segment in
                BarMark(
                    x: .value("Dia", segment.date, unit: .day),
                    y: .value("Horas", segment.hours))
                .foregroundStyle(by: .value("Perfil", segment.profileName))
                .cornerRadius(4)
            }
            .chartForegroundStyleScale(
                domain: colorDomain, range: colorRange)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text("\(Int(hours)) h")
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
            .frame(height: 220)
        }
    }

    /// Cada perfil mantém a mesma cor do popover. Domínio e faixa são
    /// arrays paralelos — sem limite de quantos perfis cabem.
    private var colorDomain: [String] {
        Set(segments.map(\.profileName)).sorted()
    }

    private var colorRange: [Color] {
        colorDomain.map { name in
            profiles.first { $0.name == name }?.accentColor ?? .gray
        }
    }
}

// MARK: - Top apps

private struct TopAppsChart: View {
    let report: UsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Apps mais usados", detail: "top \(report.topApps.count)")

            Chart(report.topApps) { app in
                BarMark(
                    x: .value("Horas", app.total / 3600),
                    y: .value("App", app.appName))
                .foregroundStyle(.blue.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(DurationFormat.short(app.total))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text("\(Int(hours)) h")
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading)
            }
            // Espaço à direita para os rótulos das barras não serem cortados.
            .chartXScale(domain: 0...(maxHours * 1.18))
            .frame(height: CGFloat(report.topApps.count) * 28 + 40)
        }
    }

    private var maxHours: Double {
        max(0.5, (report.apps.first?.total ?? 0) / 3600)
    }
}

// MARK: - Por perfil

private struct ProfileBreakdown: View {
    let report: UsageReport
    let profiles: [Profile]

    private struct Row: Identifiable {
        var id: UUID
        var name: String
        var color: Color
        var total: TimeInterval
        var share: Double
    }

    private var rows: [Row] {
        let assigned = report.perProfile.values.reduce(0, +)
        guard assigned > 0 else { return [] }
        return report.perProfile
            .compactMap { profileID, total -> Row? in
                guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
                return Row(
                    id: profileID, name: profile.name, color: profile.accentColor,
                    total: total, share: total / assigned)
            }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Distribuição por perfil")

                VStack(spacing: 10) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Circle().fill(row.color).frame(width: 7, height: 7)
                                Text(row.name).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(DurationFormat.short(row.total))
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                Text("\(Int(row.share * 100))%")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }

                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary)
                                    Capsule()
                                        .fill(row.color.gradient)
                                        .frame(width: geometry.size.width * row.share)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Apoio

private struct SectionHeading: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct EmptyWeek: View {
    let isCurrentWeek: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text(isCurrentWeek ? "Ainda sem dados nesta semana" : "Nenhum dado nesta semana")
                .font(.system(size: 14, weight: .medium))

            Text(
                isCurrentWeek
                    ? "O WakeUpeer registra o tempo enquanto você trabalha. Volte daqui a pouco."
                    : "O rastreamento pode não estar ativo nesse período."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
