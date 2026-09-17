import Testing

@Suite("Placeholder")
struct PlaceholderTests {
    @Test("o alvo compila")
    func compiles() { #expect(Bool(true)) }
}
