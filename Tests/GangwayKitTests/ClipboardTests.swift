import XCTest
@testable import GangwayKit

final class ClipboardContentTests: XCTestCase {

    func testRoundTripsMultipleRepresentations() throws {
        let content = ClipboardContent(items: [
            ClipboardItem(representations: [
                "public.utf8-plain-text": Data("hello".utf8),
                "public.rtf": Data("{\\rtf1 hello}".utf8),
            ]),
        ])
        XCTAssertEqual(try ClipboardContent.decode(try content.encoded()), content)
    }

    /// Binary plist stores Data natively; base64 would inflate images by a third.
    func testEncodingDoesNotBase64ExpandBinaryData() throws {
        let image = Data(repeating: 0xAB, count: 300_000)
        let content = ClipboardContent(items: [
            ClipboardItem(representations: ["public.png": image]),
        ])
        let encoded = try content.encoded()
        XCTAssertLessThan(encoded.count, Int(Double(image.count) * 1.1),
                          "encoding should be near-verbatim, not base64")
    }

    func testTotalBytesSumsAllRepresentations() {
        let content = ClipboardContent(items: [
            ClipboardItem(representations: ["a": Data(count: 10), "b": Data(count: 5)]),
            ClipboardItem(representations: ["c": Data(count: 7)]),
        ])
        XCTAssertEqual(content.totalBytes, 22)
    }

    func testEmptyContentRoundTrips() throws {
        let content = ClipboardContent(items: [])
        XCTAssertEqual(try ClipboardContent.decode(try content.encoded()), content)
    }
}

final class ClipboardTransferTests: XCTestCase {

    private func reassemble(_ chunks: [Data]) throws -> Data? {
        var assembler = ClipboardAssembler()
        var result: Data?
        for chunk in chunks {
            if let complete = try assembler.accept(chunk) { result = complete }
        }
        return result
    }

    func testRoundTripsPayloadSmallerThanOneChunk() throws {
        let payload = Data("a modest clipboard".utf8)
        let chunks = ClipboardTransfer.chunks(of: payload, transferID: 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(try reassemble(chunks), payload)
    }

    func testRoundTripsPayloadSpanningManyChunks() throws {
        let payload = Data((0..<(ClipboardTransfer.chunkSize * 3 + 1234))
            .map { UInt8($0 % 251) })
        let chunks = ClipboardTransfer.chunks(of: payload, transferID: 7)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(try reassemble(chunks), payload)
    }

    func testExactMultipleOfChunkSize() throws {
        let payload = Data(repeating: 0x5A, count: ClipboardTransfer.chunkSize * 2)
        let chunks = ClipboardTransfer.chunks(of: payload, transferID: 3)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(try reassemble(chunks), payload)
    }

    func testEmptyPayloadRoundTrips() throws {
        let chunks = ClipboardTransfer.chunks(of: Data(), transferID: 9)
        XCTAssertEqual(try reassemble(chunks), Data())
    }

    func testChunksReassembleOutOfOrder() throws {
        let payload = Data((0..<(ClipboardTransfer.chunkSize * 2 + 99)).map { UInt8($0 % 253) })
        let chunks = ClipboardTransfer.chunks(of: payload, transferID: 11).reversed()
        XCTAssertEqual(try reassemble(Array(chunks)), payload)
    }

    /// A peer that disconnects mid-copy must not wedge the receiver: a newer transfer
    /// supersedes the abandoned one.
    func testNewTransferSupersedesAbandonedOne() throws {
        var assembler = ClipboardAssembler()
        let abandoned = ClipboardTransfer.chunks(
            of: Data(repeating: 1, count: ClipboardTransfer.chunkSize * 2), transferID: 100)
        XCTAssertNil(try assembler.accept(abandoned[0]))

        let good = Data("second copy".utf8)
        let chunks = ClipboardTransfer.chunks(of: good, transferID: 101)
        XCTAssertEqual(try assembler.accept(chunks[0]), good)
    }

    func testRejectsOversizedTransfer() {
        var assembler = ClipboardAssembler()
        // Claim many chunks, then feed enough bytes to blow the ceiling.
        let huge = Data(repeating: 0, count: ClipboardTransfer.chunkSize)
        var threw = false
        for index in 0..<(ClipboardTransfer.maxTotalSize / ClipboardTransfer.chunkSize + 2) {
            var frame = Data()
            frame.appendLE(UInt64(1))
            frame.appendLE(UInt32(index))
            frame.appendLE(UInt32(100_000))
            frame.append(huge)
            do {
                _ = try assembler.accept(frame)
            } catch {
                guard case ClipboardAssembler.AssemblyError.tooLarge = error else {
                    return XCTFail("wrong error: \(error)")
                }
                threw = true
                break
            }
        }
        XCTAssertTrue(threw, "an unbounded transfer must be refused")
    }

    func testRejectsTruncatedHeader() {
        var assembler = ClipboardAssembler()
        XCTAssertThrowsError(try assembler.accept(Data([1, 2, 3])))
    }

    func testRejectsIndexBeyondCount() {
        var assembler = ClipboardAssembler()
        var frame = Data()
        frame.appendLE(UInt64(1))
        frame.appendLE(UInt32(5))
        frame.appendLE(UInt32(2))
        frame.append(Data("x".utf8))
        XCTAssertThrowsError(try assembler.accept(frame))
    }

    func testRejectsZeroChunkCount() {
        var assembler = ClipboardAssembler()
        var frame = Data()
        frame.appendLE(UInt64(1))
        frame.appendLE(UInt32(0))
        frame.appendLE(UInt32(0))
        XCTAssertThrowsError(try assembler.accept(frame))
    }

    func testEveryChunkFitsInAFrame() {
        let payload = Data(repeating: 0, count: ClipboardTransfer.chunkSize * 3)
        for chunk in ClipboardTransfer.chunks(of: payload, transferID: 1) {
            XCTAssertLessThanOrEqual(chunk.count, Framing.maxFrameSize)
        }
    }
}
