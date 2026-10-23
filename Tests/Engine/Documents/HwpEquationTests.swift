// Upstream regression cases: Unhwp (MIT), Copyright (c) iyulab.
// Commit 405b17e137b3ca06299dcbc8a156599ac7027e91; docs/upstream/Unhwp.LICENSE.
import XCTest
@testable import FileToXEngineKit

final class HwpEquationTests: XCTestCase {
    func testUpstreamCases() {
        let cases: [(String, String)] = [
            ("x", "x"),
            ("ALPHA", "\\alpha"),
            ("OMEGA", "\\omega"),
            ("GAMMA2", "\\Gamma"),
            ("SQRT{x}", "\\sqrt{x}"),
            ("SQRT{x+y}", "\\sqrt{x+y}"),
            ("SIN{x}", "\\sin{x}"),
            ("COS THETA", "\\cos\\theta"),
            ("a TIMES b", "a\\times b"),
            ("x LEQ y", "x\\leq y"),
            ("INT", "\\int"),
            ("OINT", "\\oint"),
            ("INFTY", "\\infty"),
            ("FRAC{a}{b}", "\\frac{a}{b}"),
            ("a OVER{b}", "\\frac{a}{b}"),
            ("x OVER{y+z}", "\\frac{x}{y+z}"),
            ("HAT{x}", "\\hat{x}"),
            ("VEC{v}", "\\vec{v}"),
            ("a DIVIDE b DIVIDE 4", "a\\div b\\div 4"),
            ("LEFT ( x RIGHT )", "\\left(x\\right)"),
            ("BAR{AB}", "\\bar{AB}"),
            ("VERT x VERT", "|x|"),
            ("BAR{rm AB}", "\\bar{AB}"),
            ("A,`B", "A,\\,B"),
            ("5a-{1} over {2} b^{2}", "5a-\\frac{1}{2}b^{2}"),
            ("{4b} over a", "\\frac{4b}{a}"),
            ("SQRT{x} over 2", "\\frac{\\sqrt{x}}{2}"),
            ("A+-SQRT{B}", "A\\pm \\sqrt{B}"),
            ("a-+b", "a\\mp b"),
            ("a+b-c", "a+b-c")
        ]
        for (script, expected) in cases { XCTAssertEqual(HwpEquationConverter.toLatex(script), expected, script) }
        let matrix = HwpEquationConverter.toLatex("MATRIX{a & b # c & d}")
        XCTAssertTrue(matrix.contains("\\begin{pmatrix}"))
        XCTAssertTrue(matrix.contains("\\end{pmatrix}"))
    }
    func testIndexedRootAndWordBoundaries() {
        XCTAssertEqual(HwpEquationConverter.toLatex("sqrt {3} of {5}"), "\\sqrt[3]{5}")
        XCTAssertEqual(HwpEquationConverter.toLatex("ROOT 3 OF {5}"), "\\sqrt[3]{5}")
        XCTAssertEqual(HwpEquationConverter.toLatex("sqrt{x} omega"), "\\sqrt{x}\\omega")
        XCTAssertEqual(HwpEquationConverter.toLatex("INT x"), "\\int x")
        XCTAssertEqual(HwpEquationConverter.toLatex("ALPHA x"), "\\alpha x")
        XCTAssertEqual(HwpEquationConverter.toLatex("SUP {2} SUB n"), "^{2}_n")
        XCTAssertEqual(HwpEquationConverter.toLatex("LEFT {a_n RIGHT }"), "\\left\\{a_n\\right\\}")
    }
    func testDeepAndMalformedInputTerminates() {
        let script = String(repeating: "SQRT{", count: 300) + "x" + String(repeating: "}", count: 300)
        XCTAssertFalse(HwpEquationConverter.toLatex(script).isEmpty)
        XCTAssertEqual(HwpEquationConverter.toLatex("SQRT{x"), "\\sqrt{x}")
        XCTAssertEqual(HwpEquationConverter.toLatex("}"), "}")
    }
}
