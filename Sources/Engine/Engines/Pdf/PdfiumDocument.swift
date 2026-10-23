// PDFtoImage 5.2.1's PdfFile / PdfDocument call sequence, without the managed/Skia wrappers.
import CPDFium
import CoreGraphics
import Foundation

/// All PDFium entry points, including lifetime operations, share this lock across every conversion route.
final class PdfiumDocument {
    static let version = "PDFium 147.0.7690.0"
    private static let lock = NSLock()
    private static let initialized: Void = FPDF_InitLibrary()

    private let bytes: NSData // FPDF_LoadMemDocument64 borrows these bytes until CloseDocument.
    private let document: FPDF_DOCUMENT
    private let form: FPDF_FORMHANDLE
    private let formInfo: UnsafeMutablePointer<FPDF_FORMFILLINFO>
    let pageCount: Int

    init(_ path: String, unreadableMessage: String? = nil) throws {
        let cannotRead = unreadableMessage ?? "\(FilePath.fileName(path)) is not a PDF file that can be read."
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw ConversionError(cannotRead) }
        bytes = data as NSData
        Self.lock.lock()
        defer { Self.lock.unlock() }
        _ = Self.initialized
        guard let loaded = FPDF_LoadMemDocument64(bytes.bytes, bytes.length, nil) else {
            if FPDF_GetLastError() == FPDF_ERR_PASSWORD {
                throw ConversionError("The PDF is password-protected. Open it with its password and save a copy without one, then convert that copy.")
            }
            throw ConversionError(cannotRead)
        }
        let info = UnsafeMutablePointer<FPDF_FORMFILLINFO>.allocate(capacity: 1)
        info.initialize(to: FPDF_FORMFILLINFO())
        info.pointee.version = 1 // PDFtoImage supplies no callbacks, JavaScript or XFA.
        guard let environment = FPDFDOC_InitFormFillEnvironment(loaded, info) else {
            info.deinitialize(count: 1)
            info.deallocate()
            FPDF_CloseDocument(loaded)
            throw ConversionError("The page could not be rendered.")
        }
        document = loaded
        form = environment
        formInfo = info
        pageCount = Int(FPDF_GetPageCount(loaded))
        FPDF_SetFormFieldHighlightColor(form, 0, 0xFFE4DD)
        FPDF_SetFormFieldHighlightAlpha(form, 100)
    }

    deinit {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        FPDFDOC_ExitFormFillEnvironment(form)
        FPDF_CloseDocument(document)
        formInfo.deinitialize(count: 1)
        formInfo.deallocate()
    }

    /// PDFium resolves crop/media box intersection and intrinsic page rotation itself.
    func pageSize(_ index: Int) throws -> CGSize {
        try Self.lock.withLock { try sizeUnlocked(index) }
    }

    private func sizeUnlocked(_ index: Int) throws -> CGSize {
        guard index >= 0, index < pageCount else { throw ConversionError("The page could not be rendered.") }
        var width = 0.0, height = 0.0
        guard FPDF_GetPageSizeByIndex(document, Int32(index), &width, &height) != 0 else {
            throw ConversionError("The page could not be rendered.")
        }
        return CGSize(width: width, height: height)
    }

    func render(_ index: Int, dpi: Int) throws -> CGImage {
        try Self.lock.withLock {
            try Task.checkCancellation()
            let size = try sizeUnlocked(index)
            let scale = Float(dpi) / 72
            let w = Float(size.width) * scale, h = Float(size.height) * scale
            guard w.isFinite, h.isFinite, w > 0, h > 0, w < Float(Int32.max / 4), h < Float(Int32.max) else {
                throw ConversionError("The page could not be rendered.")
            }
            let width = max(1, Int(w)), height = max(1, Int(h))
            guard width * height <= Int32.max / 4,
                  let bitmap = FPDFBitmap_CreateEx(Int32(width), Int32(height), FPDFBitmap_BGRA, nil, Int32(width * 4)) else {
                throw ConversionError("The page is too large to render (\(width) × \(height) pixels).")
            }
            defer { FPDFBitmap_Destroy(bitmap) }
            FPDFBitmap_FillRect(bitmap, 0, 0, Int32(width), Int32(height), 0xFFFFFFFF)
            guard let page = FPDF_LoadPage(document, Int32(index)) else { throw ConversionError("The page could not be rendered.") }
            let text = FPDFText_LoadPage(page)
            FORM_OnAfterLoadPage(page, form)
            defer {
                FORM_OnBeforeClosePage(page, form)
                if let text { FPDFText_ClosePage(text) }
                FPDF_ClosePage(page)
            }
            // Bitmap dimensions truncate; the drawing rectangle uses Ceiling, even with no explicit Bounds.
            let drawWidth = Int32(ceil(w)), drawHeight = Int32(ceil(h))
            FPDF_RenderPageBitmap(bitmap, page, 0, 0, drawWidth, drawHeight, 0, FPDF_ANNOT)
            FPDF_RemoveFormFieldHighlight(form)
            FPDF_FFLDraw(form, bitmap, page, 0, 0, drawWidth, drawHeight, 0, FPDF_ANNOT)
            try Task.checkCancellation()
            guard let buffer = FPDFBitmap_GetBuffer(bitmap) else { throw ConversionError("The page could not be rendered.") }
            let stride = Int(FPDFBitmap_GetStride(bitmap))
            let pixels = Data(bytes: buffer, count: stride * height)
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw ConversionError("The page could not be rendered.")
            }
            return image
        }
    }
}
