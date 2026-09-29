import Foundation

@main
struct ResolverChecks {
    static func main() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = CurrentWallpaperResolver(homeDirectory: root)
        let videos = resolver.aerialsDirectory.appendingPathComponent("videos", isDirectory: true)
        try fileManager.createDirectory(at: resolver.storeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let assetID = "3FD9FD5C-6DC5-4362-9932-4087C942F1C5"
        let videoURL = videos.appendingPathComponent("\(assetID).mov")
        try Data([0]).write(to: videoURL)
        var passed = 0

        func settings(provider: String = "com.apple.wallpaper.choice.aerials", id: String = assetID) throws -> [String: Any] {
            let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": id], format: .binary, options: 0)
            return ["Desktop": ["Content": ["Choices": [["Provider": provider, "Configuration": configuration]]]]]
        }

        func write(_ index: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
            try data.write(to: resolver.storeDirectory.appendingPathComponent("Index.plist"), options: .atomic)
        }

        func expectFailure(_ result: Result<ResolvedWallpaper, CurrentWallpaperResolver.ResolutionError>?, _ error: CurrentWallpaperResolver.ResolutionError) {
            guard case .failure(let actual) = result, actual == error else { fatalError("预期 \(error)，实际 \(String(describing: result))") }
            passed += 1
        }

        try write(["AllSpacesAndDisplays": settings(), "Displays": [:], "Spaces": [:]])
        let unified = try resolver.resolve(displayIDs: ["display-a", "display-b"])
        for id in ["display-a", "display-b"] {
            let video = try unified[id]!.get()
            precondition(video.assetID == assetID && video.videoURL == videoURL)
            passed += 1
        }

        try write(["AllSpacesAndDisplays": settings(), "Displays": ["display-b": settings(provider: "com.apple.wallpaper.choice.image")]])
        let separate = try resolver.resolve(displayIDs: ["display-a", "display-b"])
        let unchanged = try separate["display-a"]!.get()
        precondition(unchanged.assetID == assetID)
        passed += 1
        expectFailure(separate["display-b"], .notAerial)

        try write(["AllSpacesAndDisplays": settings(id: UUID().uuidString)])
        expectFailure(try resolver.resolve(displayIDs: ["display-a"])["display-a"], .videoNotDownloaded)

        try write(["AllSpacesAndDisplays": settings(id: "../../other-file")])
        expectFailure(try resolver.resolve(displayIDs: ["display-a"])["display-a"], .unsupportedConfiguration)

        try write(["SystemDefault": settings()])
        expectFailure(try resolver.resolve(displayIDs: ["display-a"])["display-a"], .unsupportedConfiguration)

        try write(["AllSpacesAndDisplays": settings(), "Spaces": ["another-space": settings()]])
        expectFailure(try resolver.resolve(displayIDs: ["display-a"])["display-a"], .independentSpaces)

        var shuffled = try settings()
        var desktop = shuffled["Desktop"] as! [String: Any]
        var content = desktop["Content"] as! [String: Any]
        content["Shuffle"] = ["Enabled": true]
        desktop["Content"] = content
        shuffled["Desktop"] = desktop
        try write(["AllSpacesAndDisplays": shuffled])
        expectFailure(try resolver.resolve(displayIDs: ["display-a"])["display-a"], .shuffleSelection)

        try Data("broken plist".utf8).write(to: resolver.storeDirectory.appendingPathComponent("Index.plist"))
        do {
            _ = try resolver.resolve(displayIDs: ["display-a"])
            fatalError("损坏配置不应被接受")
        } catch { passed += 1 }

        print("解析检查通过：\(passed) 项")
        if CommandLine.arguments.contains("--live") {
            let selection = try CurrentWallpaperResolver().resolve(displayIDs: ["live-global"])["live-global"]!.get()
            print("本机当前壁纸：\(selection.name) · \(selection.assetID)")
            precondition(fileManager.isReadableFile(atPath: selection.videoURL.path))
        }
    }
}
