import Foundation

enum AudioMultipartFormData {
    static func body(
        fields: [String: String],
        fileFieldName: String,
        fileURL: URL,
        mimeType: String,
        boundary: String
    ) throws -> Data {
        var data = Data()
        let separator = "--\(boundary)\r\n"

        for (key, value) in fields {
            data.append(Data(separator.utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            data.append(Data(value.utf8))
            data.append(Data("\r\n".utf8))
        }

        let fileData = try Data(contentsOf: fileURL)
        data.append(Data(separator.utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "flac":
            return "audio/flac"
        case "mp3", "mpga":
            return "audio/mpeg"
        case "mp4":
            return "video/mp4"
        case "mpeg":
            return "video/mpeg"
        case "m4a":
            return "audio/mp4"
        case "ogg":
            return "audio/ogg"
        case "wav":
            return "audio/wav"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }
}
