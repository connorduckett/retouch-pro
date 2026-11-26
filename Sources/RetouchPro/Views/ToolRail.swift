import SwiftUI

struct ToolRail: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                ToolRailButton(tool: tool, selected: model.tool == tool, enabled: model.hasImage) {
                    model.tool = tool
                }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 78)
        .background(Color.rpPaper)
    }
}

private struct ToolRailButton: View {
    let tool: Tool
    let selected: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tool.icon)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(height: 22)
                Text(tool.title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
            }
            .foregroundColor(!enabled ? .rpSilver : selected ? .white : .rpCharcoal)
            .frame(width: 62, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected && enabled ? Color.rpAccent : (hover && enabled ? Color.rpMist : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(Text(verbatim: tool.letter.isEmpty ? tool.title : "\(tool.title) (\(tool.letter))"))
        .onHover { hover = $0 }
    }
}
