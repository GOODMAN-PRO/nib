# F103: print metrics tokens

**Filed by:** F103 (Text documents: comments, outline & export). **Affects:** NibDesign (DESIGN.md §15.6 tokens).

## Gap

Printing and PDF export of text documents lay text out on paper. NibDesign has screen tokens only, so three paper
measures are literals in `TextDocPrintMetrics` (FeatTextDoc/TextDocExporter.swift):

| Literal | Value | Meaning |
|---|---|---|
| `margin` | 54 pt | Page margin on every side (three quarters of an inch). |
| `typeScale` | 0.7 | Printed type = the reading column's roles at the Large Dynamic Type size × 0.7 (body 17 pt prints at 11.9 pt). Spacing tokens are scaled by it too. |
| `footerHeight` | `NibSpacing.x3` | The page number's band at the foot of each page. |

The other features that print or export to paper (F067's print sheet, notebook and whiteboard PDF export) need the
same measures, and each would otherwise pick its own.

## Request

`NibPrint` (or `NibMetrics` additions) in NibDesign:

```swift
public enum NibPrint {
    /// Page margin on every side (pt).
    public static let margin: CGFloat = 54
    /// Type on paper, relative to the Large Dynamic Type size of the screen roles.
    public static let typeScale: CGFloat = 0.7
    /// The band that holds page numbers at the foot of a page (pt).
    public static let footerHeight: CGFloat = 32
}
```

F103 then reads them in `TextDocPrintMetrics`.
