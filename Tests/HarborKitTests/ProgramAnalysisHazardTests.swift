import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HarborKit

/// What a hostile or changing executable may cost the reader (#86).
@Suite struct ProgramAnalysisHazardTests {
    let fm = FileManager.default

    /// An .ico file holding one PNG of `side` pixels a side, as Windows Vista and later store large icons.
    static func ico(side: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
        // Width and height 0 stand for "256 or more"; the PNG itself says how large.
        return Data([0, 0, 1, 0, 1, 0] + [0, 0, 0, 0, 1, 0, 32, 0] + u32(png.count) + u32(22)) + (png as Data)
    }

    /// 2 MB of PNG can declare dimensions that take gigabytes to decode: nothing above 1024 pixels is decoded.
    @Test func iconsLargerThanAnyIconAreNotDecoded() throws {
        #expect(PEFile.pngFromICO(try Self.ico(side: 256)) != nil)
        #expect(PEFile.pngFromICO(try Self.ico(side: 1024)) != nil)
        #expect(PEFile.pngFromICO(try Self.ico(side: 1025)) == nil)
        #expect(PEFile.pngFromICO(try Self.ico(side: 4096)) == nil)
    }

    /// A version resource that claims megabytes isn't copied out of the file to be searched.
    @Test func aVersionResourceOfMegabytesIsNotRead() throws {
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        var bytes = try Data(contentsOf: app)
        let original = try #require(PEFile(bytes))
        let version = try #require(original.resources(type: 16).first)
        func u32(_ v: Int) -> Data { Data((0..<4).map { UInt8(v >> (8 * $0) & 0xFF) }) }
        // The resource's data entry: its RVA, then its size. Room for the claimed size follows the file.
        let entry = try #require(bytes.range(of: u32(version.rva) + u32(version.size)))
        bytes.append(Data(count: 3 << 20))
        #expect(try #require(PEFile(bytes)).versionStrings()["ProductName"] == "Fixture App")
        bytes.replaceSubrange(entry.lowerBound + 4 ..< entry.upperBound, with: u32(2 << 20))
        #expect(try #require(PEFile(bytes)).versionStrings().isEmpty)
    }

    /// Files of modest size are read, larger ones mapped; the analysis is the same either way.
    @Test func readAndMappedFilesAnalyseAlike() throws {
        let app = try #require(Bundle.module.url(forResource: "app64", withExtension: "exe"))
        let read = try ProgramAnalysis.contents(of: app), mapped = try ProgramAnalysis.contents(of: app, mapAbove: 0)
        #expect(read == mapped && !read.isEmpty)
        #expect(throws: (any Error).self) { try ProgramAnalysis.contents(of: URL(filePath: "/nonexistent/x.exe")) }
    }
}
