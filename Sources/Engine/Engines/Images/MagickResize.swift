// ImageMagick 7.1.2-32 Q8 ResizeImage (MagickCore/resize.c): two separable passes with the filter ImageMagick picks,
// 8-bit samples between and after the passes. The C# helper's ImageMagick was built by clang for arm64, which fuses
// `a * b + c` within a C statement (-ffp-contract=on); the same fused multiply-adds are written out here with
// `addingProduct`, because results that land on a rounding tie (x.5) otherwise come out one level apart.

import Foundation

enum MagickResize {
    /// The filters Filee's resizes end up with: ImageMagick's default choice (Lanczos, or Mitchell for pictures with
    /// alpha or a palette and for enlargements) and the explicit Lanczos of the ICNS writer.
    enum Filter {
        case point, lanczos, mitchell

        /// Support of the weighting function (resize_filter->support × blur 1).
        var support: Double {
            switch self {
            case .point: 0
            case .lanczos: 3
            case .mitchell: 2
            }
        }

        /// GetResizeFilterWeight for this filter at distance `x`.
        func weight(_ x: Double) -> Double {
            let x = abs(x)
            switch self {
            case .point: return 1
            // SincFast windowed by SincFast scaled to the 3-lobe support.
            case .lanczos: return MagickResize.sincFast(x * (1.0 / 3.0)) * MagickResize.sincFast(x)
            // Cubic B = C = 1/3, Box window.
            case .mitchell: return MagickResize.cubicBC(x)
            }
        }
    }

    /// ImageMagick's choice for `ResizeImage(..., UndefinedFilter)`. `palette`: a PseudoClass picture.
    static func defaultFilter(from source: (width: Int, height: Int), to size: (width: Int, height: Int), alpha: Bool, palette: Bool) -> Filter {
        let x = Double(size.width) * (1.0 / Double(source.width)), y = Double(size.height) * (1.0 / Double(source.height))
        if x == 1 && y == 1 { return .point }
        return palette || alpha || x * y > 1 ? .mitchell : .lanczos
    }

    /// Resizes interleaved 8-bit samples (`channels` per pixel, alpha last when `alpha`, not premultiplied).
    static func resize(_ samples: [UInt8], width: Int, height: Int, channels: Int, alpha: Bool, to size: (width: Int, height: Int),
                       filter: Filter) -> [UInt8] {
        let xFactor = Double(size.width) * (1.0 / Double(width)), yFactor = Double(size.height) * (1.0 / Double(height))
        if xFactor > yFactor {
            let between = pass(samples, width: width, height: height, channels: channels, alpha: alpha, horizontal: true, length: size.width,
                               factor: xFactor, filter: filter)
            return pass(between, width: size.width, height: height, channels: channels, alpha: alpha, horizontal: false, length: size.height,
                        factor: yFactor, filter: filter)
        }
        let between = pass(samples, width: width, height: height, channels: channels, alpha: alpha, horizontal: false, length: size.height,
                           factor: yFactor, filter: filter)
        return pass(between, width: width, height: size.height, channels: channels, alpha: alpha, horizontal: true, length: size.width,
                    factor: xFactor, filter: filter)
    }

    private static let epsilon = 1.0e-12

    /// HorizontalFilter / VerticalFilter: resamples along one axis to `length` samples.
    private static func pass(_ source: [UInt8], width: Int, height: Int, channels: Int, alpha: Bool, horizontal: Bool, length: Int,
                             factor: Double, filter: Filter) -> [UInt8] {
        let extent = horizontal ? width : height
        var scale = max(1.0 / factor + epsilon, 1.0)
        var support = scale * filter.support
        if support < 0.5 {
            support = 0.5 // too small even for nearest neighbour: point sampling
            scale = 1.0
        }
        scale = reciprocal(scale)
        // Contributing source positions and normalized weights of every output position.
        var starts = [Int](repeating: 0, count: length), counts = [Int](repeating: 0, count: length)
        var weights: [[Double]] = Array(repeating: [], count: length)
        for i in 0..<length {
            let bisect = (Double(i) + 0.5) / factor + epsilon
            let start = Int(max(bisect - support + 0.5, 0.0)), stop = Int(min(bisect + support + 0.5, Double(extent)))
            var w = [Double](), density = 0.0
            for n in 0..<max(stop - start, 0) {
                let value = filter.weight(scale * (Double(start + n) - bisect + 0.5))
                w.append(value)
                density += value
            }
            if density != 0 && density != 1 {
                density = reciprocal(density)
                for n in w.indices { w[n] *= density }
            }
            (starts[i], counts[i], weights[i]) = (start, w.count, w)
        }
        let (outWidth, outHeight) = horizontal ? (length, height) : (width, length)
        var result = [UInt8](repeating: 0, count: outWidth * outHeight * channels)
        let color = alpha ? channels - 1 : channels
        source.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                let output = output // shared by the threads: each writes its own lines
                DispatchQueue.concurrentPerform(iterations: horizontal ? outHeight : outWidth) { line in
                    for i in 0..<length {
                        let (x, y) = horizontal ? (i, line) : (line, i)
                        let w = weights[i], start = starts[i]
                        guard !w.isEmpty else { continue } // ImageMagick leaves such pixels as cloned (black)
                        // Offset of contribution n in the source and the stride between contributions.
                        let first = horizontal ? (y * width + start) * channels : (start * width + x) * channels
                        let stride = horizontal ? channels : width * channels
                        let target = (y * outWidth + x) * channels
                        for c in 0..<channels {
                            var pixel = 0.0
                            if c < color && alpha {
                                var gamma = 0.0
                                for n in 0..<w.count {
                                    let p = first + n * stride
                                    let a = w[n] * quantumScale * Double(input[p + channels - 1])
                                    pixel = pixel.addingProduct(a, Double(input[p + c]))
                                    gamma += a
                                }
                                output[target + c] = clamp(reciprocal(gamma) * pixel)
                            } else {
                                for n in 0..<w.count { pixel = pixel.addingProduct(w[n], Double(input[first + n * stride + c])) }
                                output[target + c] = clamp(pixel)
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    private static let quantumScale = 1.0 / 255.0

    /// ClampToQuantum (Q8, no HDRI).
    static func clamp(_ value: Double) -> UInt8 {
        guard value > 0 else { return 0 }
        return value >= 255 ? 255 : UInt8(value + 0.5)
    }

    /// MagickSafeReciprocal.
    static func reciprocal(_ x: Double) -> Double {
        x > -epsilon && x < epsilon ? 1.0 / epsilon : 1.0 / x
    }

    /// SincFast with the coefficients of the Q8 build (maximum relative error 6.3e-6).
    static func sincFast(_ x: Double) -> Double {
        if x > 4.0 {
            let alpha = Double.pi * x
            return sin(alpha) / alpha
        }
        let xx = x * x
        let c0 = 0.173610016489197553621906385078711564924e-2, c1 = -0.384186115075660162081071290162149315834e-3
        let c2 = 0.393684603287860108352720146121813443561e-4, c3 = -0.248947210682259168029030370205389323899e-5
        let c4 = 0.107791837839662283066379987646635416692e-6, c5 = -0.324874073895735800961260474028013982211e-8
        let c6 = 0.628155216606695311524920882748052490116e-10, c7 = -0.586110644039348333520104379959307242711e-12
        let p = c0.addingProduct(xx, c1.addingProduct(xx, c2.addingProduct(xx, c3.addingProduct(xx, c4.addingProduct(xx,
                    c5.addingProduct(xx, c6.addingProduct(xx, c7)))))))
        return (xx - 1.0) * (xx - 4.0) * (xx - 9.0) * (xx - 16.0) * p
    }

    /// CubicBC with B = C = 1/3 (Mitchell–Netravali): AcquireResizeFilter's coefficients, then CubicBC.
    static func cubicBC(_ x: Double) -> Double {
        let (p0, p2, p3, q0, q1, q2, q3) = mitchell
        if x < 1.0 { return p0.addingProduct(x, x * p2.addingProduct(x, p3)) }
        if x < 2.0 { return q0.addingProduct(x, q1.addingProduct(x, q2.addingProduct(x, q3))) }
        return 0.0
    }

    private static let mitchell: (Double, Double, Double, Double, Double, Double, Double) = {
        let b = 1.0 / 3.0, c = 1.0 / 3.0, twoB = b + b
        return (1.0.addingProduct(-(1.0 / 3.0), b), -3.0 + twoB + c, 2.0.addingProduct(-1.5, b) - c, (4.0 * c).addingProduct(4.0 / 3.0, b),
                (-twoB).addingProduct(-8.0, c), b.addingProduct(5.0, c), (-c).addingProduct(-1.0 / 6.0, b))
    }()
}
