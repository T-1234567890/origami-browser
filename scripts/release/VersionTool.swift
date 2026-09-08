import Foundation

@main struct VersionTool {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3, let build = Int(CommandLine.arguments[2]) else { throw ReleaseIdentity.InvalidRelease.build }
            let identity = try ReleaseIdentity(tag: CommandLine.arguments[1], buildNumber: build)
            var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as! [String: Any]
            result["displayVersion"] = identity.displayVersion
            result["assetName"] = identity.assetName
            result["channel"] = identity.channel
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("Invalid release tag or build number.\n".utf8)); exit(1)
        }
    }
}
