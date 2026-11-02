import Foundation

/// Quick Look only reads files, so clips held in the database are written out first.
public enum PreviewExporter {
    public static func urls(for detail: ClipDetail, service: ClipService) -> [URL] {
        if !detail.files.isEmpty {
            return detail.files.compactMap(service.resolveURL)
        }
        let directory = service.paths.previews
        let id = detail.clip.id
        for (uti, suffix) in [("public.png", "png"), ("public.jpeg", "jpg"), ("public.heic", "heic"), ("com.compuserve.gif", "gif"),
                              ("org.webmproject.webp", "webp"), ("public.tiff", "tiff")] {
            if let representation = detail.representations.first(where: { $0.uti == uti }),
               let data = try? service.data(for: representation) {
                let url = directory.appending(path: "\(id).\(suffix)")
                if (try? data.write(to: url, options: .atomic)) != nil { return [url] }
            }
        }
        for (uti, suffix) in [(PasteboardTypes.html, "html"), (PasteboardTypes.rtf, "rtf")] {
            if let representation = detail.representations.first(where: { $0.uti == uti }),
               let data = try? service.data(for: representation) {
                let url = directory.appending(path: "\(id).\(suffix)")
                if (try? data.write(to: url, options: .atomic)) != nil { return [url] }
            }
        }
        let url = directory.appending(path: "\(id).txt")
        if let text = detail.clip.plainText, (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
            return [url]
        }
        return []
    }
}
