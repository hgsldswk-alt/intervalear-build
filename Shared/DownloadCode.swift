import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

enum DownloadCode {
    static func url(storeID: String) -> String? {
        guard !storeID.isEmpty, storeID.utf8.allSatisfy({ (48...57).contains($0) }), storeID != "0" else { return nil }
        return "https://apps.apple.com/app/id\(storeID)"
    }

    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let inset = output.extent.insetBy(dx: -4, dy: -4)
        let padded = output.composited(over: CIImage(color: .white)).cropped(to: inset)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
