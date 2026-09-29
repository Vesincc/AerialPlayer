import Foundation

nonisolated struct ResolvedWallpaper: Equatable, Sendable {
    let assetID: String
    let name: String
    let videoURL: URL
}

nonisolated struct CurrentWallpaperResolver: Sendable {
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    var storeDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true)
    }

    var aerialsDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    func resolve(displayIDs: [String]) throws -> [String: Result<ResolvedWallpaper, ResolutionError>] {
        let data = try Data(contentsOf: storeDirectory.appendingPathComponent("Index.plist"))
        guard let index = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ResolutionError.unsupportedConfiguration
        }
        let manifestURL = aerialsDirectory.appendingPathComponent("manifest/entries.json")
        let manifestData = try? Data(contentsOf: manifestURL)
        let catalog = manifestData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let assets = catalog?["assets"] as? [[String: Any]] ?? []
        let strings = Bundle(url: aerialsDirectory.appendingPathComponent("manifest/TVIdleScreenStrings.bundle"))
        let displays = index["Displays"] as? [String: [String: Any]] ?? [:]
        let spaces = index["Spaces"] as? [String: Any] ?? [:]

        return Dictionary(uniqueKeysWithValues: displayIDs.map { displayID in
            let result = Result<ResolvedWallpaper, ResolutionError> { () throws(ResolutionError) -> ResolvedWallpaper in
                // Per-Space selection needs a reliable active-Space identifier; never guess from SystemDefault.
                guard spaces.isEmpty else { throw ResolutionError.independentSpaces }
                guard let settings = displays[displayID] ?? index["AllSpacesAndDisplays"] as? [String: Any],
                      let desktop = settings["Desktop"] as? [String: Any],
                      let content = desktop["Content"] as? [String: Any],
                      let choices = content["Choices"] as? [[String: Any]],
                      choices.count == 1, let choice = choices.first else {
                    throw ResolutionError.unsupportedConfiguration
                }
                if let shuffle = content["Shuffle"], shuffle as? String != "$null" {
                    throw ResolutionError.shuffleSelection
                }
                guard choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials" else {
                    throw ResolutionError.notAerial
                }
                guard let configurationData = choice["Configuration"] as? Data,
                      let configuration = try? PropertyListSerialization.propertyList(from: configurationData, format: nil) as? [String: Any],
                      let assetID = configuration["assetID"] as? String,
                      UUID(uuidString: assetID) != nil else {
                    throw ResolutionError.unsupportedConfiguration
                }
                let url = aerialsDirectory.appendingPathComponent("videos/\(assetID).mov")
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw ResolutionError.videoNotDownloaded
                }
                let entry = assets.first { $0["id"] as? String == assetID }
                let key = entry?["localizedNameKey"] as? String ?? entry?["accessibilityLabel"] as? String
                let fallback = "航拍壁纸 \(assetID.prefix(8))"
                let name = key.map { strings?.localizedString(forKey: $0, value: fallback, table: "Localizable.nocache") ?? fallback } ?? fallback
                return ResolvedWallpaper(assetID: assetID, name: name, videoURL: url)
            }
            return (displayID, result)
        })
    }

    enum ResolutionError: LocalizedError, Sendable, Equatable {
        case unsupportedConfiguration
        case independentSpaces
        case shuffleSelection
        case notAerial
        case videoNotDownloaded

        var errorDescription: String? {
            switch self {
            case .unsupportedConfiguration:
                return "无法识别当前系统壁纸配置"
            case .independentSpaces:
                return "暂不支持独立 Space 壁纸，请将航拍壁纸应用到所有空间"
            case .shuffleSelection:
                return "暂不支持随机轮播，请在系统设置中固定一张航拍壁纸"
            case .notAerial:
                return "当前壁纸不是苹果航拍视频"
            case .videoNotDownloaded:
                return "当前航拍视频尚未下载完成"
            }
        }
    }
}
