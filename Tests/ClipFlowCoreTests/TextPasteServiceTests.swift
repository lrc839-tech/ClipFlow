import Testing
@testable import ClipFlowCore

struct TextPasteServiceTests {
    @Test @MainActor func chunksPreserveUnicodeAndBoundEventSize() {
        let text = "中文🙂\n" + String(repeating: "👩‍👩‍👧‍👦Ab", count: 12)
        let chunks = TextPasteService.unicodeChunks(text)!
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 30)
        #expect(TextPasteService.unicodeChunks(oversizedGrapheme) == nil)
        #expect(TextPasteService.unicodeChunks(String(repeating: "a", count: 2049)) == nil)
    }
}
