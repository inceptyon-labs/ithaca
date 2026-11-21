import CoreGraphics
import Foundation

/// Decodes Blu-ray PGS display sets (as stored in Matroska blocks, without the
/// 13-byte `PG` .sup header) into bitmaps. Holds the epoch state (palettes and
/// objects) between blocks.
struct PGSDecoder {
    enum Output {
        case frame(ImageSubtitleFrame)
        /// The display set refers to a palette or object this decoder has not
        /// seen, so decoding started mid-epoch.
        case needsEarlierData
        /// The payload held no complete display set.
        case none
    }

    private struct PaletteEntry {
        let y: UInt8
        let cr: UInt8
        let cb: UInt8
        let alpha: UInt8
    }

    private struct PlacedObject {
        let id: UInt16
        let x: Int
        let y: Int
        let crop: (x: Int, y: Int, width: Int, height: Int)?
    }

    private struct Composition {
        let width: Int
        let height: Int
        let paletteID: UInt8
        let objects: [PlacedObject]
    }

    private struct StoredObject {
        let width: Int
        let height: Int
        let expectedLength: Int
        var rle: [UInt8]
        var isComplete: Bool
    }

    private static let maxObjectPixels = 8 << 20

    private var palettes: [UInt8: [PaletteEntry?]] = [:]
    private var objects: [UInt16: StoredObject] = [:]
    private var openObjectID: UInt16?
    private var composition: Composition?

    init() {}

    mutating func reset() {
        palettes = [:]
        objects = [:]
        openObjectID = nil
        composition = nil
    }

    /// Feeds one block payload (one or more complete segments). When it holds
    /// several display sets the last one's result is returned.
    mutating func decode(_ payload: Data) -> Output {
        let bytes = [UInt8](payload)
        var result = Output.none
        var offset = 0
        while bytes.count - offset >= 3 {
            let type = bytes[offset]
            let size = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let start = offset + 3
            guard size <= bytes.count - start else { break }
            let body = bytes[start..<(start + size)]
            switch type {
            case 0x16: beginComposition(body)
            case 0x14: storePalette(body)
            case 0x15: storeObjectFragment(body)
            case 0x80: result = finishDisplaySet()
            default: break   // WDS (0x17) and unknown segments
            }
            offset = start + size
        }
        return result
    }

    // MARK: Segments

    private mutating func beginComposition(_ body: ArraySlice<UInt8>) {
        composition = nil
        var reader = SegmentReader(body)
        guard let width = reader.u16(), let height = reader.u16(), reader.skip(1),
              reader.skip(2), let state = reader.u8(), reader.skip(1),
              let paletteID = reader.u8(), let count = reader.u8(),
              width > 0, height > 0 else { return }
        if state == 0x80 {
            palettes = [:]
            objects = [:]
            openObjectID = nil
        }
        var placed: [PlacedObject] = []
        for _ in 0..<Int(count) {
            guard let id = reader.u16(), reader.skip(1), let flags = reader.u8(),
                  let x = reader.u16(), let y = reader.u16() else { return }
            var crop: (x: Int, y: Int, width: Int, height: Int)?
            if flags & 0x80 != 0 {
                guard let cx = reader.u16(), let cy = reader.u16(),
                      let cw = reader.u16(), let ch = reader.u16() else { return }
                crop = (Int(cx), Int(cy), Int(cw), Int(ch))
            }
            placed.append(PlacedObject(id: id, x: Int(x), y: Int(y), crop: crop))
        }
        composition = Composition(width: Int(width), height: Int(height), paletteID: paletteID, objects: placed)
    }

    private mutating func storePalette(_ body: ArraySlice<UInt8>) {
        var reader = SegmentReader(body)
        guard let id = reader.u8(), reader.skip(1) else { return }
        var palette = palettes[id] ?? [PaletteEntry?](repeating: nil, count: 256)
        while let index = reader.u8(), let y = reader.u8(), let cr = reader.u8(),
              let cb = reader.u8(), let alpha = reader.u8() {
            palette[Int(index)] = PaletteEntry(y: y, cr: cr, cb: cb, alpha: alpha)
        }
        palettes[id] = palette
    }

    private mutating func storeObjectFragment(_ body: ArraySlice<UInt8>) {
        var reader = SegmentReader(body)
        guard let id = reader.u16(), reader.skip(1), let sequence = reader.u8() else { return }
        if sequence & 0x80 != 0 {
            openObjectID = nil
            guard let length = reader.u24(), let width = reader.u16(), let height = reader.u16(),
                  width > 0, height > 0, Int(width) * Int(height) <= Self.maxObjectPixels else { return }
            // The length counts the 4 bytes of width and height.
            let expected = max(Int(length) - 4, 0)
            objects[id] = StoredObject(
                width: Int(width), height: Int(height), expectedLength: expected,
                rle: [], isComplete: false
            )
            openObjectID = id
        } else if openObjectID != id {
            return
        }
        guard var object = objects[id] else { return }
        let room = object.expectedLength - object.rle.count
        object.rle.append(contentsOf: reader.rest().prefix(max(room, 0)))
        if sequence & 0x40 != 0 {
            object.isComplete = true
            openObjectID = nil
        }
        objects[id] = object
    }

    private mutating func finishDisplaySet() -> Output {
        guard let composition else { return .none }
        self.composition = nil
        let canvas = CGSize(width: composition.width, height: composition.height)
        if composition.objects.isEmpty {
            return .frame(ImageSubtitleFrame(canvasSize: canvas, images: []))
        }
        guard let palette = palettes[composition.paletteID] else { return .needsEarlierData }
        let table = Self.colorTable(palette, canvasHeight: composition.height)

        var images: [ImageSubtitleFrame.Image] = []
        for placed in composition.objects {
            guard let object = objects[placed.id], object.isComplete else { return .needsEarlierData }
            if let image = Self.render(object, placed: placed, table: table) { images.append(image) }
        }
        return .frame(ImageSubtitleFrame(canvasSize: canvas, images: images))
    }

    // MARK: Rendering

    private static func render(_ object: StoredObject, placed: PlacedObject, table: [UInt8]) -> ImageSubtitleFrame.Image? {
        var area = (x: 0, y: 0, width: object.width, height: object.height)
        if let crop = placed.crop {
            let x = min(crop.x, object.width)
            let y = min(crop.y, object.height)
            area = (x, y, min(crop.width, object.width - x), min(crop.height, object.height - y))
        }
        guard area.width > 0, area.height > 0 else { return nil }

        let indices = decodeRLE(object.rle, width: object.width, height: object.height)
        var rgba = [UInt8](repeating: 0, count: area.width * area.height * 4)
        for row in 0..<area.height {
            let source = (area.y + row) * object.width + area.x
            let target = row * area.width * 4
            for column in 0..<area.width {
                let entry = Int(indices[source + column]) * 4
                let out = target + column * 4
                rgba[out] = table[entry]
                rgba[out + 1] = table[entry + 1]
                rgba[out + 2] = table[entry + 2]
                rgba[out + 3] = table[entry + 3]
            }
        }
        guard let image = makeImage(rgba, width: area.width, height: area.height) else { return nil }
        let frame = CGRect(x: placed.x, y: placed.y, width: area.width, height: area.height)
        return ImageSubtitleFrame.Image(image: image, frame: frame)
    }

    /// Run-length decoding into palette indices, one byte per pixel. Runs are
    /// clamped to the bitmap so corrupt data cannot write out of bounds.
    static func decodeRLE(_ rle: [UInt8], width: Int, height: Int) -> [UInt8] {
        let total = width * height
        var out = [UInt8](repeating: 0, count: total)
        var position = 0
        var index = 0
        decoding: while index < rle.count, position < total {
            let byte = rle[index]
            index += 1
            if byte != 0 {
                out[position] = byte
                position += 1
                continue
            }
            guard index < rle.count else { break }
            let flags = rle[index]
            index += 1
            if flags == 0 {
                let column = position % width
                if column != 0 { position += width - column }
                continue
            }
            let length: Int
            var color: UInt8 = 0
            switch flags >> 6 {
            case 0:
                length = Int(flags & 0x3F)
            case 1:
                guard index < rle.count else { break decoding }
                length = Int(flags & 0x3F) << 8 | Int(rle[index])
                index += 1
            case 2:
                guard index < rle.count else { break decoding }
                length = Int(flags & 0x3F)
                color = rle[index]
                index += 1
            default:
                guard index + 1 < rle.count else { break decoding }
                length = Int(flags & 0x3F) << 8 | Int(rle[index])
                color = rle[index + 1]
                index += 2
            }
            let run = min(length, total - position)
            if color != 0 {
                for offset in position..<(position + run) { out[offset] = color }
            }
            position += run
        }
        return out
    }

    /// 256 premultiplied RGBA entries. Unset entries and index 0xFF are transparent.
    private static func colorTable(_ palette: [PaletteEntry?], canvasHeight: Int) -> [UInt8] {
        // BT.709 for HD canvases, BT.601 for SD.
        let (kr, kb) = canvasHeight >= 720 ? (0.2126, 0.0722) : (0.299, 0.114)
        let kg = 1 - kr - kb
        var table = [UInt8](repeating: 0, count: 256 * 4)
        for index in 0..<255 {
            guard let entry = palette[index], entry.alpha > 0 else { continue }
            let y = (Double(entry.y) - 16) * 255 / 219
            let pr = (Double(entry.cr) - 128) * 255 / 224
            let pb = (Double(entry.cb) - 128) * 255 / 224
            let r = y + 2 * (1 - kr) * pr
            let b = y + 2 * (1 - kb) * pb
            let g = (y - kr * r - kb * b) / kg
            let alpha = Int(entry.alpha)
            for (channel, value) in [r, g, b].enumerated() {
                let clamped = Int(max(0, min(255, value)).rounded())
                table[index * 4 + channel] = UInt8((clamped * alpha + 127) / 255)
            }
            table[index * 4 + 3] = entry.alpha
        }
        return table
    }

    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Bounds-checked big-endian reads over one segment body.
private struct SegmentReader {
    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    mutating func u8() -> UInt8? {
        guard offset < bytes.endIndex else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard let high = u8(), let low = u8() else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func u24() -> UInt32? {
        guard let high = u8(), let low = u16() else { return nil }
        return UInt32(high) << 16 | UInt32(low)
    }

    mutating func skip(_ count: Int) -> Bool {
        guard bytes.endIndex - offset >= count else { return false }
        offset += count
        return true
    }

    mutating func rest() -> ArraySlice<UInt8> {
        defer { offset = bytes.endIndex }
        return bytes[offset...]
    }
}
