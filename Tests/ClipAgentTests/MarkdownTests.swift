import Testing
@testable import ClipAgent

@Suite struct MarkdownBlockTests {
    @Test func parsesTheBlocksRepliesUse() {
        let source = """
        ## 结果

        找到两条：
        - 第一条
        - 第二条

        1. 先备份
        2. 再清理

        > 注意事项

        ```bash
        ls -la
        ```
        """
        #expect(MarkdownBlock.parse(source) == [
            .heading(level: 2, text: "结果"),
            .paragraph("找到两条："),
            .bullets(["第一条", "第二条"]),
            .numbered(["先备份", "再清理"]),
            .quote("注意事项"),
            .code(language: "bash", text: "ls -la"),
        ])
    }

    @Test func unfinishedFenceRendersWhileStreaming() {
        #expect(MarkdownBlock.parse("```swift\nlet a = 1") == [.code(language: "swift", text: "let a = 1")])
    }

    @Test func consecutiveLinesStayOneParagraph() {
        #expect(MarkdownBlock.parse("一行\n两行\n\n三行") == [.paragraph("一行\n两行"), .paragraph("三行")])
    }

    @Test func hashWithoutSpaceIsNotAHeading() {
        #expect(MarkdownBlock.parse("#FF8A1F 是颜色") == [.paragraph("#FF8A1F 是颜色")])
    }

    @Test func markdownInsideCodeIsLeftAlone() {
        #expect(MarkdownBlock.parse("```\n# 注释\n- 列表\n```") == [.code(language: nil, text: "# 注释\n- 列表")])
    }
}
