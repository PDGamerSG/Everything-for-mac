import Foundation

/// A displayable / searchable property of a file.
public struct Property: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable { case text, number, size, date, duration, bool, list, attributes }
    public enum Source: Equatable, Hashable, Sendable { case index, stat, spotlight(String), derived, content, history, fileList }

    public let id: String          // canonical (e.g. "date-modified")
    public let title: String       // column title
    public let kind: Kind
    public let source: Source
    public let advanced: Bool      // hidden unless "Show advanced properties"
    public let fastSortable: Bool  // index-backed sort

    public init(id: String, title: String, kind: Kind, source: Source, advanced: Bool = false, fastSortable: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.source = source; self.advanced = advanced; self.fastSortable = fastSortable
    }

    public var canonical: String { QueryParser.canonical(id) }
}

public enum PropertyCatalog {
    public static let all: [Property] = {
        var p: [Property] = []
        func add(_ id: String, _ title: String, _ kind: Property.Kind, _ source: Property.Source, advanced: Bool = false, fast: Bool = false) {
            p.append(Property(id: id, title: title, kind: kind, source: source, advanced: advanced, fastSortable: fast))
        }
        // Index-backed
        add("name", "Name", .text, .index, fast: true)
        add("path", "Path", .text, .index, fast: true)
        add("full-path", "Full Path", .text, .index, fast: true)
        add("size", "Size", .size, .index, fast: true)
        add("extension", "Extension", .text, .index, fast: true)
        add("type", "Type", .text, .derived, fast: true)
        add("kind", "Kind", .text, .derived, advanced: true)
        add("perceived-type", "Perceived Type", .text, .derived, advanced: true)
        add("date-modified", "Date Modified", .date, .index, fast: true)
        add("date-created", "Date Created", .date, .index, fast: true)
        add("date-accessed", "Date Accessed", .date, .index, fast: true)
        add("date-changed", "Date Changed", .date, .index, advanced: true, fast: true)
        add("attributes", "Attributes", .attributes, .index, fast: true)
        add("date-recently-changed", "Date Recently Changed", .date, .history, fast: true)
        add("run-count", "Run Count", .number, .history, fast: true)
        add("date-run", "Date Run", .date, .history, fast: true)
        add("stem", "Stem", .text, .index, advanced: true)
        add("name-length", "Name Length", .number, .index, advanced: true)
        add("full-path-length", "Full Path Length", .number, .index, advanced: true)
        add("depth", "Depth", .number, .index, advanced: true)
        add("child-count", "Child Count", .number, .index, advanced: true)
        add("child-file-count", "Child File Count", .number, .index, advanced: true)
        add("child-folder-count", "Child Folder Count", .number, .index, advanced: true)
        add("descendant-count", "Descendant Count", .number, .index, advanced: true)
        add("file-id", "File ID", .number, .index, advanced: true)
        add("volume-label", "Volume Label", .text, .index, advanced: true)
        add("filelist-filename", "File List Filename", .text, .fileList, advanced: true)
        add("network-index-host", "Network Index Host", .text, .index, advanced: true)
        // stat-backed
        add("size-on-disk", "Size on Disk", .size, .stat, advanced: true)
        add("owner", "Owner", .text, .stat, advanced: true)
        add("hard-link-count", "Hard Link Count", .number, .stat, advanced: true)
        add("xattr-count", "Extended Attribute Count", .number, .stat, advanced: true)
        add("xattr-names", "Extended Attribute Names", .list, .stat, advanced: true)
        add("shortcut-target", "Link Target", .text, .derived, advanced: true)
        add("url", "URL", .text, .derived, advanced: true)
        add("content-type", "Content Type", .text, .derived, advanced: true)
        add("file-signature", "File Signature", .text, .content, advanced: true)
        add("character-encoding", "Character Encoding", .text, .content, advanced: true)
        add("line-count", "Line Count", .number, .content, advanced: true)
        add("word-count", "Word Count", .number, .content, advanced: true)
        add("digital-signature-name", "Code Signature", .text, .derived, advanced: true)
        add("digital-signature-timestamp", "Code Signature Timestamp", .date, .derived, advanced: true)
        add("is-running", "Running", .bool, .derived, advanced: true)
        add("version", "Version", .text, .spotlight("kMDItemVersion"))
        add("product-name", "Product Name", .text, .derived, advanced: true)
        add("product-version", "Product Version", .text, .derived, advanced: true)
        add("container-file-count", "Container File Count", .number, .content, advanced: true)
        add("container-filenames", "Container Filenames", .list, .content, advanced: true)
        for h in ["crc32", "crc64", "md5", "sha1", "sha256", "sha512"] { add(h, h.uppercased(), .text, .content, advanced: true) }
        // Spotlight-backed
        let sp: [(String, String, Property.Kind, String)] = [
            ("title", "Title", .text, "kMDItemTitle"), ("authors", "Authors", .list, "kMDItemAuthors"), ("artist", "Artist", .list, "kMDItemAuthors"),
            ("album", "Album", .text, "kMDItemAlbum"), ("album-artist", "Album Artist", .text, "kMDItemAlbum"), ("genre", "Genre", .text, "kMDItemMusicalGenre"),
            ("composer", "Composer", .text, "kMDItemComposer"), ("year", "Year", .number, "kMDItemRecordingYear"), ("track", "Track", .number, "kMDItemAudioTrackNumber"),
            ("length", "Length", .duration, "kMDItemDurationSeconds"), ("audio-bitrate", "Audio Bitrate", .number, "kMDItemAudioBitRate"),
            ("audio-sample-rate", "Audio Sample Rate", .number, "kMDItemAudioSampleRate"), ("audio-channels", "Audio Channels", .number, "kMDItemAudioChannelCount"),
            ("total-bitrate", "Total Bitrate", .number, "kMDItemTotalBitRate"), ("video-bitrate", "Video Bitrate", .number, "kMDItemVideoBitRate"),
            ("audio-format", "Audio Format", .list, "kMDItemCodecs"), ("video-format", "Video Format", .list, "kMDItemCodecs"),
            ("beats-per-minute", "Beats Per Minute", .number, "kMDItemTempo"), ("initial-key", "Initial Key", .text, "kMDItemKeySignature"),
            ("comment", "Comment", .text, "kMDItemComment"), ("copyright", "Copyright", .text, "kMDItemCopyright"), ("publisher", "Publisher", .list, "kMDItemPublishers"),
            ("producer", "Producer", .list, "kMDItemProducer"), ("director", "Director", .list, "kMDItemDirector"), ("writer", "Writer", .list, "kMDItemLyricist"),
            ("encoded-by", "Encoded By", .list, "kMDItemEncodingApplications"), ("software", "Software", .list, "kMDItemEncodingApplications"),
            ("description", "Description", .text, "kMDItemDescription"), ("subject", "Subject", .text, "kMDItemSubject"), ("tags", "Tags", .list, "kMDItemUserTags"),
            ("rating", "Rating", .number, "kMDItemStarRating"), ("language", "Language", .list, "kMDItemLanguages"), ("company", "Company", .list, "kMDItemOrganizations"),
            ("category", "Category", .text, "kMDItemAppleDescription"), ("page-count", "Page Count", .number, "kMDItemNumberOfPages"),
            ("date-content-created", "Date Content Created", .date, "kMDItemContentCreationDate"), ("date-added", "Date Added", .date, "kMDItemDateAdded"),
            ("last-author", "Last Author", .text, "kMDItemLastUsedDate"), ("width", "Width", .number, "kMDItemPixelWidth"), ("height", "Height", .number, "kMDItemPixelHeight"),
            ("bit-depth", "Bit Depth", .number, "kMDItemBitsPerSample"), ("date-taken", "Date Taken", .date, "kMDItemContentCreationDate"),
            ("camera-maker", "Camera Maker", .text, "kMDItemAcquisitionMake"), ("camera-model", "Camera Model", .text, "kMDItemAcquisitionModel"),
            ("f-stop", "F-Stop", .number, "kMDItemFNumber"), ("exposure-time", "Exposure Time", .number, "kMDItemExposureTimeSeconds"), ("iso-speed", "ISO Speed", .number, "kMDItemISOSpeed"),
            ("focal-length", "Focal Length", .number, "kMDItemFocalLength"), ("35mm-focal-length", "35mm Focal Length", .number, "kMDItemFocalLength35mm"),
            ("latitude", "Latitude", .number, "kMDItemLatitude"), ("longitude", "Longitude", .number, "kMDItemLongitude"), ("altitude", "Altitude", .number, "kMDItemAltitude"),
            ("orientation", "Orientation", .text, "kMDItemOrientation"), ("horizontal-resolution", "Horizontal Resolution", .number, "kMDItemResolutionWidthDPI"),
            ("vertical-resolution", "Vertical Resolution", .number, "kMDItemResolutionHeightDPI"), ("lens-model", "Lens Model", .text, "kMDItemLensModel"),
            ("white-balance", "White Balance", .text, "kMDItemWhiteBalance"), ("flash-mode", "Flash Mode", .text, "kMDItemFlashOnOff"),
            ("exposure-program", "Exposure Program", .text, "kMDItemExposureProgram"), ("metering-mode", "Metering Mode", .text, "kMDItemMeteringMode"),
            ("exposure-bias", "Exposure Bias", .number, "kMDItemExposureMode"), ("max-aperture", "Max Aperture", .number, "kMDItemMaxAperture"),
            ("aperture", "Aperture", .number, "kMDItemAperture"), ("exif-version", "EXIF Version", .text, "kMDItemEXIFVersion"), ("color-space", "Color Space", .text, "kMDItemColorSpace"),
            ("from", "From", .list, "kMDItemAuthorEmailAddresses"), ("to", "To", .list, "kMDItemRecipientEmailAddresses"), ("date-received", "Date Received", .date, "kMDItemContentCreationDate"),
            ("date-sent", "Date Sent", .date, "kMDItemContentCreationDate"), ("people", "People", .list, "kMDItemParticipants"), ("mood", "Mood", .text, "kMDItemComment"),
            ("subtitle", "Subtitle", .text, "kMDItemHeadline"), ("date-released", "Date Released", .date, "kMDItemContentCreationDate"), ("date-encoded", "Date Encoded", .date, "kMDItemContentCreationDate"),
            ("audio-bits-per-sample", "Audio Bits Per Sample", .number, "kMDItemAudioBitsPerSample"), ("audio-track-count", "Audio Track Count", .number, "kMDItemAudioTrackCount"),
            ("video-track-count", "Video Track Count", .number, "kMDItemVideoTrackCount"), ("subtitle-track-count", "Subtitle Track Count", .number, "kMDItemSubtitleTrackCount"),
            ("frame-rate", "Frame Rate", .number, "kMDItemVideoFrameRate"), ("frame-count", "Frame Count", .number, "kMDItemFrameCount"),
            ("date-acquired", "Date Acquired", .date, "kMDItemDateAdded"), ("content-status", "Content Status", .text, "kMDItemContentStatus"),
            ("document-content-type", "Document Content Type", .text, "kMDItemContentType"), ("date-printed", "Date Printed", .date, "kMDItemLastPrintedDate"),
            ("date-saved", "Date Saved", .date, "kMDItemContentModificationDate"), ("slide-count", "Slide Count", .number, "kMDItemNumberOfPages"),
            ("total-editing-time", "Total Editing Time", .duration, "kMDItemEditingTime"), ("trademarks", "Trademarks", .text, "kMDItemCopyright"),
            ("parental-rating", "Parental Rating", .text, "kMDItemAudiences"), ("parental-rating-reason", "Parental Rating Reason", .text, "kMDItemAudiences"),
            ("part-of-set", "Part of Set", .text, "kMDItemAlbum"), ("period", "Period", .text, "kMDItemMusicalGenre"), ("conductor", "Conductor", .list, "kMDItemPerformers"),
            ("protected", "Protected", .bool, "kMDItemIsProtected"), ("part-of-a-compilation", "Part of a Compilation", .bool, "kMDItemIsCompilation"),
            ("brightness", "Brightness", .number, "kMDItemExposureMode"), ("contrast", "Contrast", .text, "kMDItemAcquisitionModel"), ("saturation", "Saturation", .text, "kMDItemAcquisitionModel"),
            ("light-source", "Light Source", .text, "kMDItemWhiteBalance"), ("subject-distance", "Subject Distance", .number, "kMDItemFocalLength"),
        ]
        for (id, title, kind, key) in sp { add(id, title, kind, .spotlight(key), advanced: true) }
        add("dimensions", "Dimensions", .text, .derived, advanced: true)
        add("aspect-ratio", "Aspect Ratio", .text, .derived, advanced: true)
        for i in 0...9 { add("regmatch\(i)", "Regular Expression Match \(i)", .text, .derived, advanced: true) }
        return p
    }()

    public static let byCanonical: [String: Property] = {
        var m: [String: Property] = [:]
        for p in all { m[p.canonical] = p }
        // aliases
        let alias: [String: String] = ["dm": "datemodified", "dc": "datecreated", "da": "dateaccessed", "rc": "daterecentlychanged", "ext": "extension",
                                       "fullpath": "fullpath", "loc": "path", "location": "path", "namelen": "namelength", "fullpathlen": "fullpathlength",
                                       "parentcount": "depth", "duration": "length", "author": "authors", "tag": "tags", "bpm": "beatsperminute", "fps": "framerate",
                                       "runcount": "runcount", "daterun": "daterun", "wide": "width", "high": "height", "bpp": "bitdepth", "fstop": "fstop",
                                       "sizeondisk": "sizeondisk", "adscount": "xattrcount", "adsnames": "xattrnames", "frn": "fileid", "pathlen": "fullpathlength"]
        for (a, c) in alias { if let p = m[c] { m[a] = p } }
        return m
    }()

    public static func property(_ name: String) -> Property? { byCanonical[QueryParser.canonical(name)] }

    /// Default visible columns.
    public static let defaultColumns = ["name", "path", "size", "date-modified"]
}
