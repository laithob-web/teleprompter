import AppKit

/// Turns a `ParsedScript` into the attributed string shown in the panel.
/// Ranges recorded by the parser index into `ParsedScript.displayText`, so this
/// must not insert or remove characters — styling only.
enum ScriptRenderer {

    static func attributedString(
        for script: ParsedScript,
        fontSize: CGFloat,
        textColor: NSColor,
        headingColor: NSColor,
        haloColor: NSColor?
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(string: script.displayText)
        let full = NSRange(location: 0, length: out.length)

        let bodyParagraph = NSMutableParagraphStyle()
        // Generous leading — teleprompter text is read in peripheral vision and
        // tight line spacing is the main cause of losing your place.
        bodyParagraph.lineHeightMultiple = 1.35
        // Sole source of the gap between paragraphs, now that blank lines are
        // collapsed in the parser.
        bodyParagraph.paragraphSpacing = fontSize * 0.5
        bodyParagraph.alignment = .left
        bodyParagraph.lineBreakMode = .byWordWrapping

        var bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: bodyParagraph,
        ]
        if let haloColor {
            // Zero offset so it reads as an outline rather than a drop shadow.
            let halo = NSShadow()
            halo.shadowColor = haloColor
            halo.shadowBlurRadius = max(3, fontSize * 0.14)
            halo.shadowOffset = .zero
            bodyAttributes[.shadow] = halo
        }
        out.addAttributes(bodyAttributes, range: full)

        // Headings are signposts you glance at, never read aloud — so they are
        // deliberately smaller and dimmer than the body text.
        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.lineHeightMultiple = 1.1
        // Gap between a heading and the answer under it. Kept tight: they are
        // one unit, and the space before the heading is what separates sections.
        headingParagraph.paragraphSpacing = fontSize * 0.12
        headingParagraph.paragraphSpacingBefore = fontSize * 0.7

        for section in script.sections where section.titleRange.length > 0 {
            guard NSMaxRange(section.titleRange) <= out.length else { continue }
            out.addAttributes([
                .font: NSFont.systemFont(ofSize: fontSize * 0.62, weight: .semibold),
                .foregroundColor: headingColor,
                .paragraphStyle: headingParagraph,
                .kern: fontSize * 0.02,
            ], range: section.titleRange)
        }

        return out
    }
}
