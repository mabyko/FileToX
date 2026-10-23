// Media links (Markdig's MediaLinks extension): an image whose URL is a YouTube, Vimeo, Yandex Music or OK video
// becomes an <iframe>, one whose file extension is audio or video an <audio> / <video> element.

import Foundation

extension Markdown {
    final class MediaLinkExtension: PipelineExtension {
        private static let width = "500"
        private static let height = "281"

        private static let extensionToMimeType: [(String, String)] = [
            (".3gp", "video/3gpp"), (".3g2", "video/3gpp2"), (".avi", "video/x-msvideo"), (".uvh", "video/vnd.dece.hd"),
            (".uvm", "video/vnd.dece.mobile"), (".uvu", "video/vnd.uvvu.mp4"), (".uvp", "video/vnd.dece.pd"),
            (".uvs", "video/vnd.dece.sd"), (".uvv", "video/vnd.dece.video"), (".fvt", "video/vnd.fvt"), (".f4v", "video/x-f4v"),
            (".flv", "video/x-flv"), (".fli", "video/x-fli"), (".h261", "video/h261"), (".h263", "video/h263"),
            (".h264", "video/h264"), (".jpm", "video/jpm"), (".jpgv", "video/jpeg"), (".m4v", "video/x-m4v"),
            (".asf", "video/x-ms-asf"), (".pyv", "video/vnd.ms-playready.media.pyv"), (".wm", "video/x-ms-wm"),
            (".wmx", "video/x-ms-wmx"), (".wmv", "video/x-ms-wmv"), (".wvx", "video/x-ms-wvx"), (".mj2", "video/mj2"),
            (".mxu", "video/vnd.mpegurl"), (".mpeg", "video/mpeg"), (".mp4", "video/mp4"), (".ogv", "video/ogg"),
            (".webm", "video/webm"), (".qt", "video/quicktime"), (".movie", "video/x-sgi-movie"), (".viv", "video/vnd.vivo"),
            (".adp", "audio/adpcm"), (".aac", "audio/x-aac"), (".aif", "audio/x-aiff"), (".uva", "audio/vnd.dece.audio"),
            (".eol", "audio/vnd.digital-winds"), (".dra", "audio/vnd.dra"), (".dts", "audio/vnd.dts"),
            (".dtshd", "audio/vnd.dts.hd"), (".rip", "audio/vnd.rip"), (".lvp", "audio/vnd.lucent.voice"),
            (".m3u", "audio/x-mpegurl"), (".pya", "audio/vnd.ms-playready.media.pya"), (".wma", "audio/x-ms-wma"),
            (".wax", "audio/x-ms-wax"), (".mid", "audio/midi"), (".mp3", "audio/mpeg"), (".mpga", "audio/mpeg"),
            (".mp4a", "audio/mp4"), (".ecelp4800", "audio/vnd.nuera.ecelp4800"), (".ecelp7470", "audio/vnd.nuera.ecelp7470"),
            (".ecelp9600", "audio/vnd.nuera.ecelp9600"), (".oga", "audio/ogg"), (".ogg", "audio/ogg"), (".weba", "audio/webm"),
            (".ram", "audio/x-pn-realaudio"), (".rmp", "audio/x-pn-realaudio-plugin"), (".au", "audio/basic"),
            (".wav", "audio/x-wav"),
        ]

        /// Known hosts in Markdig's order: host prefix, iframe URL from the URI, full screen allowed, class.
        private static let hosts: [(String, (WebUri) -> String?, Bool, String)] = [
            ("www.youtube.com", youTubeShort, true, "youtubeshort"),
            ("www.youtube.com", youTube, true, "youtube"),
            ("youtu.be", youTubeShortened, true, "youtube"),
            ("vimeo.com", { "https://player.vimeo.com/video/\($0.unescapedPath.split(separator: "/", omittingEmptySubsequences: false).last ?? "")" }, true, "vimeo"),
            ("music.yandex.ru", yandex, false, "yandex"),
            ("ok.ru", { "https://ok.ru/videoembed/\($0.unescapedPath.split(separator: "/", omittingEmptySubsequences: false).last ?? "")" }, true, "odnoklassniki"),
        ]

        func setupPipeline(_ builder: PipelineBuilder) {}

        func setupRenderer(_ renderer: HtmlRenderer) {
            guard let links = renderer.objectRenderers.first(where: { type(of: $0) == LinkInlineRenderer.self }) else { return }
            links.tryWriters.append { renderer, object in Self.tryLinkInlineRenderer(renderer, object as! LinkInline) }
        }

        private static func tryLinkInlineRenderer(_ renderer: HtmlRenderer, _ link: LinkInline) -> Bool {
            guard link.isImage, var url = link.url else { return false }
            if url.hasPrefix("//") { url = "https:" + url }
            guard let uri = WebUri(url) else { return false }
            if uri.isAbsolute, tryRenderIframe(uri, renderer, link) { return true }
            return tryGuessAudioVideoFile(uri, renderer, link)
        }

        private static func attributes(of link: LinkInline) -> HtmlAttributes {
            let attributes = HtmlAttributes()
            link.tryGetAttributes()?.copyTo(attributes, mergeIdAndProperties: false, shared: false)
            return attributes
        }

        private static func tryGuessAudioVideoFile(_ uri: WebUri, _ renderer: HtmlRenderer, _ link: LinkInline) -> Bool {
            let path = uri.isAbsolute ? uri.unescapedPath : uri.original
            guard let dot = path.lastIndex(of: "."),
                  let mimeType = extensionToMimeType.first(where: { $0.0.caseInsensitiveCompare(String(path[dot...])) == .orderedSame })?.1 else { return false }
            let attributes = attributes(of: link)
            let isAudio = mimeType.hasPrefix("audio")
            let tag = isAudio ? "audio" : "video"
            renderer.write("<\(tag)")
            attributes.addPropertyIfNotExist("width", width)
            if !isAudio { attributes.addPropertyIfNotExist("height", height) }
            attributes.addPropertyIfNotExist("controls", nil)
            renderer.writeAttributes(attributes)
            renderer.write("><source type=\"\(mimeType)\" src=\"\(link.url ?? "")\"></source></\(tag)>")
            return true
        }

        private static func tryRenderIframe(_ uri: WebUri, _ renderer: HtmlRenderer, _ link: LinkInline) -> Bool {
            for (prefix, handler, allowFullScreen, className) in hosts {
                guard uri.host.lowercased().hasPrefix(prefix), let iframeUrl = handler(uri), !iframeUrl.isEmpty else { continue }
                let attributes = attributes(of: link)
                renderer.write("<iframe src=\"")
                renderer.writeEscapeUrl(iframeUrl)
                renderer.write("\"" as Char)
                attributes.addPropertyIfNotExist("width", width)
                attributes.addPropertyIfNotExist("height", height)
                attributes.addClass(className)
                attributes.addPropertyIfNotExist("frameborder", "0")
                if allowFullScreen { attributes.addPropertyIfNotExist("allowfullscreen", nil) }
                renderer.writeAttributes(attributes)
                renderer.write("></iframe>")
                return true
            }
            return false
        }

        private static func queryParameters(_ uri: WebUri) -> [String] {
            uri.query.split(separator: "&").map(String.init)
        }

        private static func embedUrl(_ videoId: String?, _ startTime: String?) -> String? {
            guard let videoId, !videoId.isEmpty else { return nil }
            let url = "https://www.youtube.com/embed/\(videoId)"
            if let startTime, !startTime.isEmpty { return "\(url)?start=\(startTime)" }
            return url
        }

        private static func youTube(_ uri: WebUri) -> String? {
            let path = uri.path
            if path.lowercased() == "/embed" || path.lowercased().hasPrefix("/embed/") { return uri.description }
            if path.lowercased() != "/watch" && !path.lowercased().hasPrefix("/watch/") { return nil }
            let parameters = queryParameters(uri)
            return embedUrl(parameters.first { $0.hasPrefix("v=") }.map { String($0.dropFirst(2)) },
                            parameters.first { $0.hasPrefix("t=") }.map { String($0.dropFirst(2)) })
        }

        private static func youTubeShort(_ uri: WebUri) -> String? {
            guard uri.path.lowercased().hasPrefix("/shorts/") else { return nil }
            let rest = uri.path.dropFirst("/shorts/".count)
            return embedUrl(rest.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init), nil)
        }

        private static func youTubeShortened(_ uri: WebUri) -> String? {
            embedUrl(String(uri.path.dropFirst()), queryParameters(uri).first { $0.hasPrefix("t=") }.map { String($0.dropFirst(2)) })
        }

        private static func yandex(_ uri: WebUri) -> String? {
            let items = uri.unescapedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard items.count >= 4, items[0] == "album", items[2] == "track" else { return nil }
            return "https://music.yandex.ru/iframe/#track/\(items[3])/\(items[1])/"
        }
    }

    /// The parts of .NET's `Uri` the media links need: absolute "scheme://host/path?query#fragment" URIs (a leading
    /// "/" is an absolute file path, as .NET treats it on Unix) or relative references.
    struct WebUri: CustomStringConvertible {
        let original: String
        let isAbsolute: Bool
        var scheme = ""
        var host = ""
        var port = ""
        /// Escaped path with its leading "/" (`AbsolutePath`).
        var path = ""
        /// Query without the "?".
        var query = ""
        var fragment = ""

        init?(_ text: String) {
            original = text
            if text.hasPrefix("/") {
                isAbsolute = true
                scheme = "file"
                path = text
                return
            }
            guard let colon = text.firstIndex(of: ":"), text[..<colon].first?.isLetter == true,
                  text[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) else {
                isAbsolute = false
                return
            }
            isAbsolute = true
            scheme = text[..<colon].lowercased()
            var rest = text[text.index(after: colon)...]
            if rest.hasPrefix("//") {
                rest = rest.dropFirst(2)
                let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
                var authority = rest[..<authorityEnd]
                if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
                if let portColon = authority.lastIndex(of: ":"), !authority.contains("]") || authority.last != "]" {
                    port = String(authority[authority.index(after: portColon)...])
                    authority = authority[..<portColon]
                }
                host = authority.lowercased()
                if host.isEmpty && (scheme == "http" || scheme == "https" || scheme == "ftp") { return nil }
                rest = rest[authorityEnd...]
            }
            if let hash = rest.firstIndex(of: "#") {
                fragment = String(rest[rest.index(after: hash)...])
                rest = rest[..<hash]
            }
            if let question = rest.firstIndex(of: "?") {
                query = String(rest[rest.index(after: question)...])
                rest = rest[..<question]
            }
            path = rest.isEmpty && !host.isEmpty ? "/" : String(rest)
        }

        /// `GetComponents(UriComponents.Path, UriFormat.Unescaped)`: the path without its leading "/", unescaped.
        var unescapedPath: String {
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return trimmed.removingPercentEncoding ?? trimmed
        }

        var description: String {
            guard isAbsolute, !host.isEmpty else { return original }
            var text = "\(scheme)://\(host)"
            if !port.isEmpty { text += ":\(port)" }
            text += path
            if !query.isEmpty { text += "?\(query)" }
            if !fragment.isEmpty { text += "#\(fragment)" }
            return text
        }
    }
}
