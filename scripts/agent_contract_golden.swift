import Foundation

@main struct GoldenRunner {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let keys = root["keys"] as! [String: String]
        var hashes: [String] = []
        for object in root["packages"] as! [[String: Any]] {
            let package = try AgentPackageV1.decode(JSONSerialization.data(withJSONObject: object))
            let rebuilt = try AgentPackageV1.unsigned(package.definition)
            precondition(rebuilt.sha256 == package.sha256)
            let roundtrip = try AgentPackageV1.decode(package.encoded())
            precondition(roundtrip == package)
            if package.signature != nil { try package.verify(keys: keys) }
            hashes.append(package.sha256)
        }
        for invalid in root["invalid_json"] as! [String] {
            do { var parser = AgentCanonicalJSON.Parser(data: Data(invalid.utf8)); _ = try parser.parse(); fatalError("Accepted invalid JSON") }
            catch AgentAssetError.invalidJSON {}
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["ok": true, "packages": hashes], options: .prettyPrinted), encoding: .utf8)!)
    }
}
