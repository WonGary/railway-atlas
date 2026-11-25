import Foundation
import RailwayCore

extension RailwayMapStore {
    func loadNationalMetroOverview() {
        guard showsNationalMetroOverview else {
            nationalMetroStatus = "全国城市轨道概览 · 已关闭"
            return
        }
        guard nationalMetroWork == nil else { return }
        nationalMetroStatus = "全国地铁概览 · 正在读取"
        let repository = nationalMetroRepository
        nationalMetroWork = Task { [weak self] in
            do {
                let snapshot = try await repository.load()
                guard !Task.isCancelled, let self else { return }
                self.acceptNationalMetro(snapshot)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.nationalMetroStatus = "全国地铁概览未载入 · 可重试更新"
            }
            guard !Task.isCancelled, let self else { return }
            self.nationalMetroWork = nil
        }
    }

    func refreshNationalMetroOverview() {
        guard nationalMetroWork == nil else { return }
        nationalMetroLoading = true
        nationalMetroStatus = "正在更新全国地铁概览 · 继续显示已有线路"
        let repository = nationalMetroRepository
        nationalMetroWork = Task { [weak self] in
            do {
                let update = try await repository.refreshIncrementally()
                guard !Task.isCancelled, let self else { return }
                if update.changed != 0 || self.nationalMetroSnapshot?.sourceDate != update.snapshot.sourceDate {
                    self.acceptNationalMetro(update.snapshot)
                }
                self.nationalMetroStatus = (update.changed == 0 ? "已是发布版本，下载 0 个分块" :
                    "已更新 \(update.changed) 个城市或网络") + " · " + (update.snapshot.sourceDate ?? "")
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.nationalMetroStatus = "全国地铁更新暂不可用 · 保留已有概览"
                self.showMessage(error.localizedDescription, error: true)
            }
            guard !Task.isCancelled, let self else { return }
            self.nationalMetroLoading = false
            self.nationalMetroWork = nil
        }
    }

    func updateNationalMetroStatus(_ snapshot: NationalMetroSnapshot) {
        let date = snapshot.sourceDate.map { " · \($0)" } ?? ""
        let groups = snapshot.cityNames.filter { $0 != "未归档" }.count
        nationalMetroStatus = "全国城市轨道 · \(groups) 个城市／网络 · \(snapshot.routeCount) 条线路\(date)"
    }

    func acceptNationalMetro(_ snapshot: NationalMetroSnapshot) {
        nationalMetroSnapshot = snapshot
        guard showsNationalMetroOverview else {
            nationalMetroStatus = "全国城市轨道概览 · 已关闭"
            return
        }
        updateNationalMetroStatus(snapshot)
        publishTiles()
    }
}
