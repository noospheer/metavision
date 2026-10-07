import SwiftUI

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @State private var selection: TitleRecord?
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            columnHeaders
            Divider().overlay(Phosphor.ghost)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.groups) { group in
                        GroupSection(
                            group: group,
                            isOpen: !collapsed.contains(group.dir),
                            selection: $selection,
                            toggle: { toggle(group.dir) }
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            Divider().overlay(Phosphor.ghost)
            DetailStrip(title: selection)
            StatusLine(titles: store.titles)
        }
        .font(Phosphor.mono)
        .foregroundStyle(Phosphor.green)
        .background(Phosphor.panel)
        .task {
            store.load()
            selection = store.titles.first
        }
    }

    private func toggle(_ dir: String) {
        if collapsed.contains(dir) { collapsed.remove(dir) } else { collapsed.insert(dir) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("KLEPTON // LIBRARY").fontWeight(.semibold)
            Text("~/xr/apks").foregroundStyle(Phosphor.dim)
            Spacer()
            if let error = store.loadError {
                Text(error).font(Phosphor.label(11)).foregroundStyle(Phosphor.amber)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
    }

    private var columnHeaders: some View {
        HStack(spacing: 12) {
            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
            Text("ENGINE").frame(width: 84)
            Text("GAZE").frame(width: 78)
            Text("STATUS").frame(width: 88)
        }
        .font(Phosphor.label()).tracking(1.6)
        .foregroundStyle(Phosphor.dim)
        .padding(.horizontal, 26).padding(.bottom, 9)
    }
}

private struct GroupSection: View {
    let group: LibraryStore.Group
    let isOpen: Bool
    @Binding var selection: TitleRecord?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Text(isOpen ? "▾" : "▸").foregroundStyle(Phosphor.dim).frame(width: 10)
                    Text(group.dir).fontWeight(.semibold)
                    Text(group.meta).font(Phosphor.label(10.5)).tracking(1)
                        .foregroundStyle(Phosphor.dim)
                    Spacer()
                    Text(group.isBlocked ? "BLOCKED" : "\(group.titles.count) TITLES")
                        .font(Phosphor.label()).tracking(1.2)
                        .foregroundStyle(group.isBlocked ? Phosphor.fault : Phosphor.dim)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)

            if isOpen {
                ForEach(Array(group.titles.enumerated()), id: \.element.id) { index, title in
                    TitleRow(
                        title: title,
                        isLast: index == group.titles.count - 1,
                        isSelected: selection?.id == title.id
                    ) { selection = title }
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct TitleRow: View {
    let title: TitleRecord
    let isLast: Bool
    let isSelected: Bool
    let select: () -> Void

    private var gaze: TitleRecord.GazeModel { title.gaze ?? .none }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(isLast ? "└──" : "├──").foregroundStyle(Phosphor.ghost)
                    Text(title.displayName).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(title.backend ?? "—").font(Phosphor.label()).frame(width: 84)
                    .foregroundStyle(Phosphor.dim)
                Badge(text: gaze.rawValue, tint: gaze.tint).frame(width: 78)
                Badge(text: title.status.rawValue, tint: title.status.tint).frame(width: 88)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? Phosphor.ghost.opacity(0.4) : .clear,
                        in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .opacity(title.status.isRunnable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        // A `.none` row gets no hover affordance. The UI then tells the truth:
        // there is no gaze path on a raw framebuffer submit.
        .hoverEffect(.highlight, isEnabled: gaze.respondsToHover)
    }
}

private struct Badge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(Phosphor.label()).tracking(1)
            .foregroundStyle(tint)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tint.opacity(0.35)))
    }
}

private struct DetailStrip: View {
    let title: TitleRecord?
    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            if let title {
                field("SELECTED", title.displayName)
                if let gaze = title.gaze {
                    field("GAZE MODEL", "\(gaze.rawValue) — \(gaze.summary)")
                }
                if let note = title.note { field("NOTE", note) }
            } else {
                field("SELECTED", "—")
            }
            Spacer()
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .background(Phosphor.ground)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Phosphor.label()).tracking(1.6).foregroundStyle(Phosphor.dim)
            Text(value).font(.system(size: 12.5, design: .monospaced))
        }
    }
}

private struct StatusLine: View {
    let titles: [TitleRecord]
    var body: some View {
        HStack(spacing: 22) {
            stat("INDEXED", titles.count, Phosphor.green)
            stat("RUNNABLE", titles.filter { $0.status == .ok }.count, Phosphor.green)
            stat("NO ASSETS", titles.filter { $0.status == .noasset }.count, Phosphor.amber)
            stat("BLOCKED", titles.filter { !$0.status.isRunnable && $0.status != .noasset }.count,
                 Phosphor.fault)
            Spacer()
        }
        .font(Phosphor.label(10.5)).tracking(1.2)
        .foregroundStyle(Phosphor.dim)
        .padding(.horizontal, 26).padding(.vertical, 9)
        .background(Phosphor.ground)
    }

    private func stat(_ label: String, _ n: Int, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
            Text("\(n)").font(.system(size: 11, design: .monospaced))
                .monospacedDigit().foregroundStyle(tint)
        }
    }
}
