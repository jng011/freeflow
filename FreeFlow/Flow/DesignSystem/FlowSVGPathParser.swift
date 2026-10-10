import Foundation
import SwiftUI

/// Minimal SVG reader for stroke icons drawn in a 24x24 viewBox (Lucide).
/// Supports path (M L H V C S Q T A Z, absolute and relative), circle, ellipse,
/// rect (rx/ry), line, polyline and polygon. Transforms and styles are ignored.
enum FlowSVGPathParser {
    static func path(contentsOf url: URL) -> Path? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return path(svgData: data)
    }

    static func path(svgData data: Data) -> Path? {
        let delegate = ShapeCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.path.isEmpty else { return nil }
        return delegate.path.isEmpty ? nil : delegate.path
    }

    // MARK: - Elements

    private final class ShapeCollector: NSObject, XMLParserDelegate {
        var path = Path()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attr: [String: String] = [:]
        ) {
            func num(_ key: String, _ fallback: CGFloat = 0) -> CGFloat {
                guard let raw = attr[key] else { return fallback }
                let trimmed = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")
                return Double(trimmed).map { CGFloat($0) } ?? fallback
            }

            switch elementName.lowercased() {
            case "path":
                if let d = attr["d"] {
                    path.addPath(FlowSVGPathParser.path(d: d))
                }
            case "circle":
                let r = num("r")
                guard r > 0 else { return }
                path.addEllipse(in: CGRect(x: num("cx") - r, y: num("cy") - r, width: r * 2, height: r * 2))
            case "ellipse":
                let rx = num("rx"), ry = num("ry")
                guard rx > 0, ry > 0 else { return }
                path.addEllipse(in: CGRect(x: num("cx") - rx, y: num("cy") - ry, width: rx * 2, height: ry * 2))
            case "rect":
                let rect = CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height"))
                guard rect.width > 0, rect.height > 0 else { return }
                var rx = attr["rx"] != nil ? num("rx") : num("ry")
                var ry = attr["ry"] != nil ? num("ry") : rx
                rx = min(rx, rect.width / 2)
                ry = min(ry, rect.height / 2)
                if rx > 0 || ry > 0 {
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: rx, height: ry))
                } else {
                    path.addRect(rect)
                }
            case "line":
                path.move(to: CGPoint(x: num("x1"), y: num("y1")))
                path.addLine(to: CGPoint(x: num("x2"), y: num("y2")))
            case "polyline", "polygon":
                let values = FlowSVGPathParser.numbers(in: attr["points"] ?? "")
                guard values.count >= 4 else { return }
                var i = 0
                var first = true
                while i + 1 < values.count {
                    let point = CGPoint(x: values[i], y: values[i + 1])
                    if first {
                        path.move(to: point)
                        first = false
                    } else {
                        path.addLine(to: point)
                    }
                    i += 2
                }
                if elementName.lowercased() == "polygon" {
                    path.closeSubpath()
                }
            default:
                break
            }
        }
    }

    // MARK: - Number lists

    static func numbers(in string: String) -> [CGFloat] {
        var scanner = PathScanner(string)
        var result: [CGFloat] = []
        while let value = scanner.number() {
            result.append(value)
        }
        return result
    }

    // MARK: - Path data

    static func path(d: String) -> Path {
        var path = Path()
        var scanner = PathScanner(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8 = 0
        var hasCurrentPoint = false

        while true {
            if let letter = scanner.command() {
                command = letter
            } else if scanner.isAtEnd || command == 0 || !scanner.peekNumber() {
                break
            } else if command == UInt8(ascii: "M") {
                command = UInt8(ascii: "L")  // implicit lineto after moveto
            } else if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            } else if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                break  // numbers after closepath are invalid
            }

            let relative = command >= UInt8(ascii: "a") && command <= UInt8(ascii: "z")
            let upper = relative ? command - 32 : command
            let base = relative ? current : .zero

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: base.x + x, y: base.y + y)
            }

            var resetCubic = true
            var resetQuad = true

            switch upper {
            case UInt8(ascii: "M"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                hasCurrentPoint = true
            case UInt8(ascii: "L"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                if !hasCurrentPoint { path.move(to: current); hasCurrentPoint = true } else { path.addLine(to: current) }
            case UInt8(ascii: "H"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "C"):
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                    let x2 = scanner.number(), let y2 = scanner.number(),
                    let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c1 = point(x1, y1)
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
                resetCubic = false
            case UInt8(ascii: "S"):
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                    let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c1: CGPoint
                if let last = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    c1 = current
                }
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
                resetCubic = false
            case UInt8(ascii: "Q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                    let x = scanner.number(), let y = scanner.number()
                else { return path }
                let c = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
                resetQuad = false
            case UInt8(ascii: "T"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c: CGPoint
                if let last = lastQuadControl {
                    c = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    c = current
                }
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
                resetQuad = false
            case UInt8(ascii: "A"):
                guard let rx = scanner.number(), let ry = scanner.number(),
                    let rotation = scanner.number(),
                    let largeArc = scanner.flag(), let sweep = scanner.flag(),
                    let x = scanner.number(), let y = scanner.number()
                else { return path }
                let end = point(x, y)
                addArc(to: &path, from: current, rx: rx, ry: ry, rotationDegrees: rotation,
                       largeArc: largeArc, sweep: sweep, end: end)
                current = end
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }

            if resetCubic { lastCubicControl = nil }
            if resetQuad { lastQuadControl = nil }
        }

        return path
    }

    // MARK: - Arcs (endpoint parameterization to cubic beziers, SVG spec F.6.5)

    private static func addArc(
        to path: inout Path,
        from start: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        end: CGPoint
    ) {
        if start == end { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2
        let dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let numerator = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
        let denominator = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coefficient: CGFloat = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }

        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)

        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
        }

        var a = theta1
        for index in 0..<segments {
            let b = a + step
            let c1 = map(cos(a) - t * sin(a), sin(a) + t * cos(a))
            let c2 = map(cos(b) + t * sin(b), sin(b) - t * cos(b))
            let p = index == segments - 1 ? end : map(cos(b), sin(b))
            path.addCurve(to: p, control1: c1, control2: c2)
            a = b
        }
    }
}

// MARK: - Scanner

private struct PathScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ string: String) {
        bytes = Array(string.utf8)
    }

    var isAtEnd: Bool {
        var i = index
        while i < bytes.count, Self.isSeparator(bytes[i]) { i += 1 }
        return i >= bytes.count
    }

    private static func isSeparator(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x2C || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private mutating func skipSeparators() {
        while index < bytes.count, Self.isSeparator(bytes[index]) { index += 1 }
    }

    /// Next command letter, if the next token is one. Exponent markers never start a token.
    mutating func command() -> UInt8? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let c = bytes[index]
        let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        guard isLetter, c != UInt8(ascii: "e"), c != UInt8(ascii: "E") else { return nil }
        index += 1
        return c
    }

    mutating func peekNumber() -> Bool {
        skipSeparators()
        guard index < bytes.count else { return false }
        let c = bytes[index]
        return Self.isDigit(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
    }

    /// Arc flags may be written without separators ("a1 1 0 011 1").
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let c = bytes[index]
        if c == UInt8(ascii: "0") { index += 1; return false }
        if c == UInt8(ascii: "1") { index += 1; return true }
        return nil
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let start = index
        var i = index

        if bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
        var sawDigits = false
        while i < bytes.count, Self.isDigit(bytes[i]) { i += 1; sawDigits = true }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while i < bytes.count, Self.isDigit(bytes[i]) { i += 1; sawDigits = true }
        }
        guard sawDigits else { return nil }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") { j += 1 }
            if j < bytes.count, Self.isDigit(bytes[j]) {
                while j < bytes.count, Self.isDigit(bytes[j]) { j += 1 }
                i = j
            }
        }

        index = i
        guard let string = String(bytes: bytes[start..<i], encoding: .ascii), let value = Double(string) else {
            return nil
        }
        return CGFloat(value)
    }
}
