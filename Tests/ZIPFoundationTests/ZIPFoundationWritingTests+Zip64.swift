//
//  ZIPFoundationWritingTests+Zip64.swift
//  ZIPFoundation
//
//  Copyright © 2017-2021 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import XCTest
@testable import ZIPFoundation

extension ZIPFoundationTests {
    func testCreateZip64ArchiveWithLargeSize() {
        // Target fields:
        // Uncompressed Size, Compressed Size, Offset of Central Directory
        //
        // Expected structure:
        // 4 + 2 [Version Needed to Extract] + 12 + 4 [Uncompressed Size: 0xffffffff]
        // + 4 [Compressed Size: 0xffffffff] + 4 + n [File Name] + (2 [Header ID] + 2 [Field Length]
        // + 8 [Uncompressed Size] + 8 [Compressed Size]) + n [File Data] + 20
        // + [Uncompressed Size: 0xffffffff] + 4 [Compressed Size: 0xffffffff] + 18 + n [File Name]
        // + (2 [Header ID] + 2 [Field Length] + 8 [Uncompressed Size] + 8 [Compressed Size])
        mockIntMaxValues()
        let archive = self.archive(for: #function, mode: .create)
        let size = 64 * 64 * 2
        let data = Data.makeRandomData(size: size)
        let entryName = ProcessInfo.processInfo.globallyUniqueString
        do {
            try archive.addEntry(with: entryName, type: .file,
                                 uncompressedSize: UInt(size), provider: { (position, bufferSize) -> Data in
                                    let upperBound = Swift.min(size, position + bufferSize)
                                    let range = Range(uncheckedBounds: (lower: position, upper: upperBound))
                                    return data.subdata(in: range)
            })
        } catch {
            XCTFail("Failed to add zip64 format entry to archive with error : \(error)")
        }
        let fileSystemRepresentation = FileManager.default.fileSystemRepresentation(withPath: archive.url.path)
        guard let archiveFile = fopen(fileSystemRepresentation, "rb") else {
            XCTFail("Failed to read data of archive file.")
            return
        }
        do {
            // Local File Header and Extra Field
            // Version Needed to Extract/Uncompressed Size/Compressed Size
            fseek(archiveFile, 0, SEEK_SET)
            let lfhSize = checkLocalFileHeaderAndExtraField(dataSize: size, entryNameLength: entryName.count) { size in
                try Data.readChunk(of: size, from: archiveFile)
            }
            // Central Directory and Extra Field
            // Version Needed to Extract/Uncompressed Size/Compressed Size
            let cdOffset = lfhSize + size
            fseek(archiveFile, cdOffset, SEEK_SET)
            let cdSize = checkCentralDirectoryAndExtraField(dataSize: size, entryNameLength: entryName.count) { size in
                try Data.readChunk(of: size, from: archiveFile)
            }
            // Zip64 End of Central Directory
            let zip64EOCDOffset = cdOffset + cdSize
            fseek(archiveFile, zip64EOCDOffset, SEEK_SET)
            let zip64EOCDSize = checkZip64EndOfCentralDirectory(cdSize: cdSize, cdOffset: cdOffset,
                                                                zip64EOCDOffset: zip64EOCDOffset) { size in
                try Data.readChunk(of: size, from: archiveFile)
            }
            // End of Central Directory
            let eocdOffset = zip64EOCDOffset + zip64EOCDSize
            let eocdSize = 22
            fseek(archiveFile, eocdOffset, SEEK_SET)
            let eocdData = try Data.readChunk(of: eocdSize, from: archiveFile)
            XCTAssertEqual(eocdData.scanValue(start: 16), UInt32.max)
        } catch {
            XCTFail("Unexpected error while reading chunk from archive file.")
        }
        guard let entry = archive[entryName] else {
            XCTFail("Failed to add large entry to uncompressed archive")
            return
        }
        XCTAssert(entry.checksum == data.crc32(checksum: 0))
//        XCTAssert(archive.checkIntegrity())
    }

    private func checkLocalFileHeaderAndExtraField(dataSize: Int, entryNameLength: Int,
                                                   readData: (Int) throws -> Data) -> Int {
        do {
            let lfhExtraFieldOffset = 30 + entryNameLength
            let lfhSize = lfhExtraFieldOffset + 20
            let lfhData = try readData(lfhSize)
            XCTAssertEqual(lfhData.scanValue(start: 4), zip64Version)
            XCTAssertEqual(lfhData.scanValue(start: 18), UInt32.max)
            XCTAssertEqual(lfhData.scanValue(start: 22), UInt32.max)
            XCTAssertEqual(lfhData.scanValue(start: lfhExtraFieldOffset), UInt16(1))
            XCTAssertEqual(lfhData.scanValue(start: lfhExtraFieldOffset + 2), UInt16(16))
            XCTAssertEqual(lfhData.scanValue(start: lfhExtraFieldOffset + 4), UInt(dataSize))
            XCTAssertEqual(lfhData.scanValue(start: lfhExtraFieldOffset + 12), UInt(dataSize))
            return lfhSize
        } catch {
            XCTFail("Unexpected error while reading chunk from archive file.")
        }
        return 0
    }

    private func checkCentralDirectoryAndExtraField(dataSize: Int, entryNameLength: Int,
                                                    readData: (Int) throws -> Data) -> Int {
        do {
            let relativeCDExtraFieldOffset = 46 + entryNameLength
            let cdSize = relativeCDExtraFieldOffset + 20
            let cdData = try readData(cdSize)
            XCTAssertEqual(cdData.scanValue(start: 6), zip64Version)
            XCTAssertEqual(cdData.scanValue(start: 20), UInt32.max)
            XCTAssertEqual(cdData.scanValue(start: 24), UInt32.max)
            XCTAssertEqual(cdData.scanValue(start: relativeCDExtraFieldOffset), UInt16(1))
            XCTAssertEqual(cdData.scanValue(start: relativeCDExtraFieldOffset + 2), UInt16(16))
            XCTAssertEqual(cdData.scanValue(start: relativeCDExtraFieldOffset + 4), UInt(dataSize))
            XCTAssertEqual(cdData.scanValue(start: relativeCDExtraFieldOffset + 12), UInt(dataSize))
            return cdSize
        } catch {
            XCTFail("Unexpected error while reading chunk from archive file.")
        }
        return 0
    }

    private func checkZip64EndOfCentralDirectory(cdSize: Int, cdOffset: Int, zip64EOCDOffset: Int,
                                                 readData: (Int) throws -> Data) -> Int {
        do {
            let zip64EOCDSize = 56 + 20
            let zip64EOCDData = try readData(zip64EOCDSize)
            XCTAssertEqual(zip64EOCDData.scanValue(start: 0), UInt32(zip64EndOfCentralDirectoryRecordStructSignature))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 4), UInt(44))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 12), UInt16(789))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 14), zip64Version)
            XCTAssertEqual(zip64EOCDData.scanValue(start: 16), UInt32(0))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 20), UInt32(0))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 24), UInt(1))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 32), UInt(1))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 40), UInt(cdSize))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 48), UInt(cdOffset))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 56), UInt32(zip64EndOfCentralDirectoryLocatorStructSignature))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 60), UInt32(0))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 64), UInt(zip64EOCDOffset))
            XCTAssertEqual(zip64EOCDData.scanValue(start: 72), UInt32(1))
            return zip64EOCDSize
        } catch {
            XCTFail("Unexpected error while reading chunk from archive file.")
        }
        return 0
    }

    func testCreateZip64ArchiveWithZip64LFHOffset() {
        // Target fields:
        // Relative Offset of Local Header
        //
        // Expected structure:
        // 4 + 2 [Version Needed to Extract] + 12 + 4 [Uncompressed Size: 0xffffffff]
        // + 4 [Compressed Size: 0xffffffff] + 4 + n [File Name] + (2 [Header ID] + 2 [Field Length]
        // + 8 [Uncompressed Size] + 8 [Compressed Size]) + n [File Data] + 20
        // + [Uncompressed Size: 0xffffffff] + 4 [Compressed Size: 0xffffffff] + 18 + n [File Name]
        // + (2 [Header ID] + 2 [Field Length] + 8 [Uncompressed Size] + 8 [Compressed Size])
        mockIntMaxValues()

    }

    func testCreateZip64ArchiveWithTooManyEntries() {
        // Target fields:
        // Total Number of Entries in Central Directory, Size of Central Directory
        //
        // Expected structure:
        // 4 + 2 [Version Needed to Extract] + 12 + 4 [Uncompressed Size: 0xffffffff]
        // + 4 [Compressed Size: 0xffffffff] + 4 + n [File Name] + (2 [Header ID] + 2 [Field Length]
        // + 8 [Uncompressed Size] + 8 [Compressed Size]) + n [File Data] + 20
        // + [Uncompressed Size: 0xffffffff] + 4 [Compressed Size: 0xffffffff] + 18 + n [File Name]
        // + (2 [Header ID] + 2 [Field Length] + 8 [Uncompressed Size] + 8 [Compressed Size])
        mockIntMaxValues()
    }

    func testRemoveEntryFromZip64Archive() {
        // case 1:
        // case 2:
    }

    // MARK: - Helpers

    class func resetIntMaxValues() {
        maxUInt32 = .max
        maxUInt16 = .max
    }

    private func mockIntMaxValues() {
        maxUInt32 = UInt32(64 * 64)
        maxUInt16 = UInt16(64)
    }
}
