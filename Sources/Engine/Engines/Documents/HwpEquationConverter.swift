// Swift port of src/equation.rs from iyulab/unhwp, commit
// 405b17e137b3ca06299dcbc8a156599ac7027e91.
// https://github.com/iyulab/unhwp
//
// MIT License
//
// Copyright (c) 2025 iyulab
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import Foundation

/// Unhwp's keyword table and recursive parser. Unknown words pass through unchanged;
/// an empty result keeps the script (or a visible placeholder for a missing script).
enum HwpEquationConverter {
    static func toLatex(_ script: String) -> String { Parser(script).convert() }

    private static let keywords: [String: String] = [
        "INT": "\\int", "IINT": "\\iint", "IIINT": "\\iiint", "OINT": "\\oint", "OIINT": "\\oiint",
        "SUM": "\\sum", "PROD": "\\prod", "LIM": "\\lim", "LIMSUP": "\\limsup", "LIMINF": "\\liminf",
        "SIN": "\\sin",
        "COS": "\\cos",
        "TAN": "\\tan",
        "COT": "\\cot",
        "SEC": "\\sec",
        "CSC": "\\csc",
        "SINH": "\\sinh",
        "COSH": "\\cosh",
        "TANH": "\\tanh",
        "COTH": "\\coth",
        "ARCSIN": "\\arcsin",
        "ARCCOS": "\\arccos",
        "ARCTAN": "\\arctan",
        "LOG": "\\log",
        "LN": "\\ln",
        "EXP": "\\exp",
        "ALPHA": "\\alpha",
        "BETA": "\\beta",
        "GAMMA": "\\gamma",
        "DELTA": "\\delta",
        "EPSILON": "\\epsilon",
        "VAREPSILON": "\\varepsilon",
        "ZETA": "\\zeta",
        "ETA": "\\eta",
        "THETA": "\\theta",
        "VARTHETA": "\\vartheta",
        "IOTA": "\\iota",
        "KAPPA": "\\kappa",
        "LAMBDA": "\\lambda",
        "MU": "\\mu",
        "NU": "\\nu",
        "XI": "\\xi",
        "OMICRON": "o",
        "PI": "\\pi",
        "VARPI": "\\varpi",
        "RHO": "\\rho",
        "VARRHO": "\\varrho",
        "SIGMA": "\\sigma",
        "VARSIGMA": "\\varsigma",
        "TAU": "\\tau",
        "UPSILON": "\\upsilon",
        "PHI": "\\phi",
        "VARPHI": "\\varphi",
        "CHI": "\\chi",
        "PSI": "\\psi",
        "OMEGA": "\\omega",
        "UALPHA": "A",
        "ALPHA2": "A",
        "UBETA": "B",
        "BETA2": "B",
        "UGAMMA": "\\Gamma",
        "GAMMA2": "\\Gamma",
        "UDELTA": "\\Delta",
        "DELTA2": "\\Delta",
        "UEPSILON": "E",
        "EPSILON2": "E",
        "UZETA": "Z",
        "ZETA2": "Z",
        "UETA": "H",
        "ETA2": "H",
        "UTHETA": "\\Theta",
        "THETA2": "\\Theta",
        "UIOTA": "I",
        "IOTA2": "I",
        "UKAPPA": "K",
        "KAPPA2": "K",
        "ULAMBDA": "\\Lambda",
        "LAMBDA2": "\\Lambda",
        "UMU": "M",
        "MU2": "M",
        "UNU": "N",
        "NU2": "N",
        "UXI": "\\Xi",
        "XI2": "\\Xi",
        "UOMICRON": "O",
        "OMICRON2": "O",
        "UPI": "\\Pi",
        "PI2": "\\Pi",
        "URHO": "P",
        "RHO2": "P",
        "USIGMA": "\\Sigma",
        "SIGMA2": "\\Sigma",
        "UTAU": "T",
        "TAU2": "T",
        "UUPSILON": "\\Upsilon",
        "UPSILON2": "\\Upsilon",
        "UPHI": "\\Phi",
        "PHI2": "\\Phi",
        "UCHI": "X",
        "CHI2": "X",
        "UPSI": "\\Psi",
        "PSI2": "\\Psi",
        "UOMEGA": "\\Omega",
        "OMEGA2": "\\Omega",
        "TIMES": "\\times ",
        "DIV": "\\div ",
        "DIVIDE": "\\div ",
        "CDOT": "\\cdot ",
        "PM": "\\pm ",
        "PLUSMINUS": "\\pm ",
        "MP": "\\mp ",
        "MINUSPLUS": "\\mp ",
        "LEQ": "\\leq ",
        "LE": "\\leq ",
        "GEQ": "\\geq ",
        "GE": "\\geq ",
        "NEQ": "\\neq ",
        "NE": "\\neq ",
        "APPROX": "\\approx ",
        "EQUIV": "\\equiv ",
        "SIM": "\\sim ",
        "SIMEQ": "\\simeq ",
        "CONG": "\\cong ",
        "PROPTO": "\\propto ",
        "SUBSET": "\\subset ",
        "SUPSET": "\\supset ",
        "SUBSETEQ": "\\subseteq ",
        "SUPSETEQ": "\\supseteq ",
        "IN": "\\in ",
        "NI": "\\ni ",
        "OWNS": "\\ni ",
        "NOTIN": "\\notin ",
        "EMPTYSET": "\\emptyset",
        "CUP": "\\cup ",
        "UNION": "\\cup ",
        "CAP": "\\cap ",
        "INTER": "\\cap ",
        "INTERSECTION": "\\cap ",
        "SETMINUS": "\\setminus ",
        "BIGCUP": "\\bigcup ",
        "BIGCAP": "\\bigcap ",
        "LAND": "\\land ",
        "AND": "\\land ",
        "LOR": "\\lor ",
        "OR": "\\lor ",
        "LNOT": "\\lnot ",
        "NOT": "\\lnot ",
        "FORALL": "\\forall ",
        "EXISTS": "\\exists ",
        "NEXISTS": "\\nexists ",
        "IMPLIES": "\\Rightarrow ",
        "RIGHTARROW": "\\Rightarrow ",
        "IFF": "\\Leftrightarrow ",
        "LEFTRIGHTARROW": "\\Leftrightarrow ",
        "LEFTARROW": "\\leftarrow ",
        "LARROW": "\\leftarrow ",
        "RARROW": "\\rightarrow ",
        "UPARROW": "\\uparrow ",
        "DOWNARROW": "\\downarrow ",
        "LRARROW": "\\leftrightarrow ",
        "MAPSTO": "\\mapsto ",
        "LBRACE": "\\{",
        "RBRACE": "\\}",
        "LANGLE": "\\langle",
        "RANGLE": "\\rangle",
        "LFLOOR": "\\lfloor",
        "RFLOOR": "\\rfloor",
        "LCEIL": "\\lceil",
        "RCEIL": "\\rceil",
        "VERT": "|",
        "DVERT": "\\|",
        "DBAR": "\\|",
        "LEFT": "\\left",
        "RIGHT": "\\right",
        "LDOTS": "\\cdots",
        "CDOTS": "\\cdots",
        "DOTS": "\\cdots",
        "VDOTS": "\\vdots",
        "DDOTS": "\\ddots",
        "INFTY": "\\infty",
        "INF": "\\infty",
        "PARTIAL": "\\partial",
        "NABLA": "\\nabla",
        "PRIME": "'",
        "DPRIME": "''",
        "DEGREE": "^\\circ",
        "ANGLE": "\\angle",
        "PERP": "\\perp",
        "PARALLEL": "\\parallel",
        "DET": "\\det",
        "DIM": "\\dim",
        "GCD": "\\gcd",
        "HOM": "\\hom",
        "INF2": "\\inf",
        "KER": "\\ker",
        "MAX": "\\max",
        "MIN": "\\min",
        "MOD": "\\mod",
        "SUP2": "\\sup"
    ]

    private final class Parser {
        let chars: [Character]
        let depth: Int
        var index = 0
        var output = ""
        init(_ script: String, _ depth: Int = 0) { chars = Array(script); self.depth = depth }
        var peek: Character? { index < chars.count ? chars[index] : nil }
        @discardableResult func next() -> Character? {
            guard let c = peek else { return nil }
            index += 1
            return c
        }
        func skipWhitespace() { while peek?.isWhitespace == true { index += 1 } }
        func convert() -> String {
            // Bound recursive group parsing on untrusted document input.
            if depth >= 128 { return String(chars) }
            while peek != nil { element() }
            return output
        }
        func element() {
            skipWhitespace()
            guard let c = next() else { return }
            switch c {
            case "`": output += "\\,"
            case "+" where peek == "-": index += 1; output += "\\pm "
            case "-" where peek == "+": index += 1; output += "\\mp "
            default:
                if Self.letter(c) {
                    index -= 1
                    keyword(word())
                } else { output.append(c) }
            }
        }
        static func letter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        static func alphanumeric(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        func word() -> String {
            let start = index
            while let c = peek, Self.alphanumeric(c) { index += 1 }
            return String(chars[start..<index])
        }
        func group() -> String {
            skipWhitespace()
            guard peek == "{" else { return word() }
            index += 1
            let start = index
            var nesting = 1
            while let c = next() {
                if c == "{" { nesting += 1 }
                if c == "}" { nesting -= 1 }
                if nesting == 0 { return Parser(String(chars[start..<(index - 1)]), depth + 1).convert() }
            }
            return Parser(String(chars[start..<index]), depth + 1).convert()
        }
        func consumeWord(_ expected: String) -> Bool {
            skipWhitespace()
            let saved = index
            if word().uppercased() == expected { return true }
            index = saved
            return false
        }
        func lastExpression() -> String {
            let chars = Array(DocumentXML.trimEnd(output))
            guard let last = chars.last else { return "" }
            var start = chars.count - 1
            if last == "}" {
                var nesting = 1
                for i in stride(from: chars.count - 2, through: 0, by: -1) {
                    if chars[i] == "}" { nesting += 1 }
                    if chars[i] == "{" { nesting -= 1 }
                    if nesting == 0 {
                        start = i
                        var command = i
                        while command > 0 && Self.letter(chars[command - 1]) { command -= 1 }
                        if command > 0 && chars[command - 1] == "\\" { start = command - 1 }
                        break
                    }
                }
            } else if Self.letter(last) {
                while start > 0 && Self.letter(chars[start - 1]) { start -= 1 }
                if start > 0 && chars[start - 1] == "\\" { start -= 1 }
            } else {
                while start > 0 && !chars[start - 1].isWhitespace && chars[start - 1] != "{" && chars[start - 1] != "}" { start -= 1 }
            }
            output = String(chars[..<start])
            return stripBraces(String(chars[start...]))
        }
        func stripBraces(_ s: String) -> String {
            guard s.first == "{", s.last == "}", s.count >= 2 else { return s }
            let inner = s.dropFirst().dropLast()
            var nesting = 0
            for c in inner {
                if c == "{" { nesting += 1 }
                if c == "}" { nesting -= 1 }
                if nesting < 0 { return s }
            }
            return nesting == 0 ? String(inner) : s
        }
        func keyword(_ word: String) {
            let key = word.uppercased()
            switch key {
            case "OVER", "DOVER", "CFRAC", "TFRAC":
                let numerator = lastExpression()
                let denominator = group()
                let command = key == "TFRAC" ? "tfrac" : (key == "OVER" ? "frac" : "dfrac")
                output += "\\\(command){\(numerator)}{\(denominator)}"
            case "SQRT", "ROOT":
                let arg = group()
                // HWP uses both SQRT n OF x and ROOT n OF x for indexed roots.
                if consumeWord("OF") { output += "\\sqrt[\(arg)]{\(group())}" }
                else if key == "ROOT" { output += "\\sqrt[\(arg)]{\(group())}" }
                else { output += "\\sqrt{\(arg)}" }
            case "FRAC":
                let numerator = group(), denominator = group()
                output += "\\frac{\(numerator)}{\(denominator)}"
            case "MATRIX", "PMATRIX", "BMATRIX", "VMATRIX", "CASES":
                skipWhitespace()
                if peek == "{" {
                    let content = group().replacingOccurrences(of: "#", with: " \\\\ ")
                    let inner = key == "CASES" ? content : content.replacingOccurrences(of: "&", with: " & ")
                    let env = key == "CASES" ? "cases" : (key == "BMATRIX" ? "bmatrix" : (key == "VMATRIX" ? "vmatrix" : "pmatrix"))
                    output += "\\begin{\(env)} \(inner) \\end{\(env)}"
                }
            case "BAR", "HAT", "OVERLINE", "VEC", "DOT", "DDOT", "TILDE", "WIDETILDE", "WIDEHAT":
                output += "\\\(key.lowercased()){\(group())}"
            case "RM", "IT": break
            case "SUP": output += "^"
            case "SUB": output += "_"
            case "LEFT", "RIGHT":
                output += "\\" + key.lowercased()
                skipWhitespace()
                if peek == "{" || peek == "}" { output += "\\" + String(next()!) }
            default:
                let value = keywords[key] ?? word
                // Whitespace removal must not merge a command and its following variable (\int x).
                if value.first.map(Self.letter) == true,
                   output.range(of: #"\\[A-Za-z]+$"#, options: .regularExpression) != nil { output += " " }
                output += value
            }
        }
    }
}
