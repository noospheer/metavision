import Foundation
import Observation

/// Reconciles the two independent halves of a title.
///
/// Code is compiled into the bundle and cannot be added at runtime (AMFI blocks
/// `dlopen` outside the bundle). Assets live in Documents and can be synced any
/// time. A title needs both, and the mismatch is worth surfacing plainly.
@Observable
final class LibraryStore {
    private(set) var titles: [TitleRecord] = []
    private(set) var loadError: String?

    private let fm = FileManager.default

    var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func load() {
        do {
            let url = documents.appending(path: "manifest.json")
            guard fm.fileExists(atPath: url.path) else {
                titles = []
                loadError = "No manifest.json in Documents. Run metavision-sync."
                return
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            titles = manifest.titles.map(resolve)
            loadError = nil
        } catch {
            titles = []
            loadError = "Could not read manifest.json: \(error.localizedDescription)"
        }
    }

    /// Downgrade a triage-passing title to `.noasset` when its assets are absent.
    private func resolve(_ record: TitleRecord) -> TitleRecord {
        guard record.status.isRunnable else { return record }
        var r = record
        if !hasCode(r.pkg) {
            r.status = .abandon
            r.note = "No framework in bundle — rebuild to include this title."
        } else if !hasAssets(r.pkg) {
            r.status = .noasset
            r.note = "Code linked in, assets missing. Run metavision-sync."
        }
        return r
    }

    private func hasCode(_ pkg: String) -> Bool {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return false }
        return fm.fileExists(atPath: frameworks.appending(path: pkg).path)
    }

    private func hasAssets(_ pkg: String) -> Bool {
        let dir = documents.appending(path: "titles/\(pkg)")
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return !contents.isEmpty
    }

    // MARK: - Grouping

    struct Group: Identifiable {
        var id: String { dir }
        let dir: String
        let meta: String
        let titles: [TitleRecord]
        var isBlocked: Bool { titles.allSatisfy { !$0.status.isRunnable } }
    }

    /// Grouped by lineage rather than genre — the tree structure *is* the
    /// compatibility analysis.
    var groups: [Group] {
        let buckets: [(String, String, (TitleRecord) -> Bool)] = [
            ("shell/",     "native · RealityKit entities",  { $0.gaze == .shader }),
            ("quest/",     "arm64 · IL2CPP · OpenXR",       { $0.xr == .openxr }),
            ("quest1/",    "arm64 · VrApi · legacy",        { $0.xr == .vrapi }),
            ("blocked/",   "unsupported architecture",      { $0.status == .arch32 || $0.status == .isa }),
            ("_streaming/","CloudXR · Foveated Streaming",  { $0.gaze == .fovea }),
        ]
        var claimed = Set<String>()
        return buckets.compactMap { dir, meta, match in
            let members = titles.filter { !claimed.contains($0.pkg) && match($0) }
            members.forEach { claimed.insert($0.pkg) }
            return members.isEmpty ? nil : Group(dir: dir, meta: meta, titles: members)
        }
    }
}
