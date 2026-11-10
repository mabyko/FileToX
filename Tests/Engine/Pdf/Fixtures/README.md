# PDFium pixel reference

`pdfium.pdf` is a hand-written two-page FileToX test PDF (no external assets).
Its crop is 60.5 × 40.5 pt within a 120.5 × 90.5 pt media box; page two rotates 90°.
It contains Helvetica text, colored rectangles, 50% transparency, a blue square
annotation, and an AcroForm widget with a green appearance stream.

`pdfium_p1.png` and `pdfium_p2.png` were captured from the installed **C#**
FileToX helper using `Tools/engine-compare/run.py`, an isolated temporary library,
the built-in PNG preset with only `pdf.renderDpi = 101` changed, and this original PDF.
PDFtoImage 5.2.1 / bblanchon.PDFium.macOS 147.0.7690; no installed data was modified.
The test compares every decoded RGBA sample exactly, including annotations/forms,
white background, anti-aliasing, rotation, and ceil drawing versus truncated bitmap sizing.

SHA-256:

- `pdfium_p1.png`: `a0dcc201c4bc0463fadbd19348c783532f0a4d4837f7f715673083585c7dc4f2`
- `pdfium_p2.png`: `adf8032d1a31a8f9741ebd60626db04d2c61e02d6e9a199368ef1a2fadf13fa2`

Read through `#filePath`, like the other engine fixtures; no test resources are bundled.
