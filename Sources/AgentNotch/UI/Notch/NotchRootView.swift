import SwiftUI

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(
                topCornerRadius: viewModel.isExpanded ? 18 : 6,
                bottomCornerRadius: viewModel.isExpanded ? 24 : 16
            )
            .fill(.black.opacity(0.92))
            .shadow(color: .black.opacity(viewModel.isExpanded ? 0.24 : 0), radius: 18, y: 10)

            VStack(spacing: viewModel.isExpanded ? 12 : 0) {
                closedHeader
                    .frame(height: 36)

                if viewModel.isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, viewModel.isExpanded ? 16 : 12)
            .padding(.bottom, viewModel.isExpanded ? 16 : 0)
        }
        .foregroundStyle(.white)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.isExpanded)
        .onTapGesture {
            viewModel.toggleExpanded()
        }
    }

    private var closedHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: viewModel.representativeSession?.harness.symbolName ?? "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)

            Text(viewModel.representativeSession?.title ?? "Agent Notch")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            if viewModel.attentionCount > 0 {
                Label("\(viewModel.attentionCount)", systemImage: "exclamationmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
            } else {
                Text("\(viewModel.activeCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Grouping", selection: $viewModel.groupingMode) {
                ForEach(SessionGroupingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.groupedSessions, id: \.title) { group in
                        sessionGroup(group)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func sessionGroup(_ group: (title: String, sessions: [AgentSession])) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(group.title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.58))
                .textCase(.uppercase)

            ForEach(group.sessions) { session in
                SessionRow(session: session)
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.harness.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(session.projectName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }

                Text(session.preview)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(session.status.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(session.needsAttention ? .yellow : .white.opacity(0.62))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.white.opacity(session.needsAttention ? 0.16 : 0.08), in: Capsule())
        }
        .padding(8)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
