# Design QA: macOS Input Source Badge

## Comparison Target

- Source visual truth: `/var/folders/41/873zzyln62j9_d0hktly07040000gn/T/codex-clipboard-4152ddeb-f81a-40d0-bbd1-bb547c6a65ed.png`
- Implementation screenshot: `/var/folders/41/873zzyln62j9_d0hktly07040000gn/T/orca-computer-use/6258da7c-6e65-458b-87c6-0528cec73215-screenshot.png`
- State: macOS System Settings, Keyboard, Text Input, All Input Sources, light appearance, no row selected.
- Design intent: RimeAI's badge must match the ABC badge's outer width, height, corner treatment, visual weight, and row alignment while retaining the letter `R`; its name must occupy one vertically centered line.

## Viewport And Density

- Source: 532 x 392 px focused crop; source density is not encoded. Measurements were compared as proportions within the source crop.
- Implementation: 1446 x 1662 px at 2x density, representing a 723 x 831 pt System Settings window.
- Density normalization: implementation badge measurements were divided by 2 to recover point dimensions. The source was used as a proportional visual reference rather than treated as a 1x point layout.

## Full-view Comparison Evidence

- The final implementation preserves the native System Settings layout, typography, row spacing, labels, color, and control states.
- RimeAI remains a single input-source row with one `RimeAI` label.
- The RimeAI badge now follows the same horizontal rounded-rectangle silhouette as ABC and Pinyin instead of the earlier square silhouette.
- The RimeAI label now uses a true single-line layout. Its ink center is 0.5 physical px from the badge center, equal to ABC.

## Focused Region Comparison Evidence

- Retina pixel measurement from the implementation:
  - ABC badge: 44 x 32 px = 22 x 16 pt.
  - Pinyin badge: 44 x 32 px = 22 x 16 pt.
  - RimeAI badge: 44 x 32 px = 22 x 16 pt.
- The three badge left edges and row centers align in the same native list column.
- ABC's `A` ink bounds are 17 x 17 physical px; RimeAI's `R` ink bounds are 13 x 16 physical px. The one-pixel height difference and narrower width are accepted as the natural optical proportions of different uppercase glyphs, not a badge-size mismatch.

## Required Fidelity Surfaces

- Fonts and typography: the badge uses the macOS system bold face; `RimeAI` remains system-owned text with unchanged size, weight, single-line height, and antialiasing.
- Spacing and layout rhythm: badge dimensions are exactly aligned at 22 x 16 pt; list indentation, icon-to-label spacing, row spacing, and single-line vertical centering remain system-owned and consistent.
- Colors and visual tokens: the PDF remains a template image, so System Settings supplies the same gray tint and selected-state behavior as the native badges.
- Image quality and asset fidelity: the badge remains a vector PDF with clean Retina rendering and no raster scaling artifacts.
- Copy and content: the badge contains `R`; the row contains one `RimeAI` label.

## Findings

- No actionable P0, P1, or P2 differences remain.
- [P3] The `R` is naturally narrower than the native `A`. Stretching it to the same ink width would distort the letterform, so its natural width is retained.

## Comparison History

1. Initial implementation: the RimeAI badge was square and visibly narrower than ABC. This was a P1 mismatch against the requested ABC alignment.
2. First fix: changed the visible badge to 22 x 16 pt with a 5 pt corner radius. After restarting System Settings to clear its PDF cache, all three badges measured 22 x 16 px on a 1x display.
3. Typography refinement: reduced the `R` from 12.5 pt after it rendered one pixel taller than `A`; 11.5 pt then rendered too small. The final 12 pt setting renders the `R` at 16 physical px high against `A` at 17 physical px high on the 2x capture.
4. Final comparison: source and implementation were opened together. The outer geometry, alignment, color treatment, typography style, and content pass; only the acceptable P3 natural-glyph-width difference remains.
5. Single-line correction: the localized bundle name previously contained an invisible `U+2060`, which kept the system subtitle slot nonempty and placed `RimeAI` 10.5 physical px above the badge center. Replacing it with a true empty string collapsed the subtitle slot; the final offset is 0.5 physical px, matching ABC.

## Implementation Checklist

- [x] Match ABC badge width and height.
- [x] Match horizontal rounded-rectangle treatment.
- [x] Preserve optical vertical centering for `R`.
- [x] Rebuild and install the input method.
- [x] Restart System Settings to invalidate the old icon cache.
- [x] Verify the final Retina rendering and code signature.

final result: passed
