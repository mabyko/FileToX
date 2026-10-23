// The drawing header (ACadSharp CadHeader): every system variable with ACadSharp's defaults, the $VARIABLE map
// the DXF reader and writer use, and .NET-compatible date and time span values for TDCREATE / TDINDWG round trips.

import Foundation

extension ACad {
    /// .NET `DateTime` (ticks of 100 ns since 0001-01-01, no time zone), so ACadSharp's Julian date conversions give
    /// the same values.
    struct CadDateTime: Hashable {
        var ticks: Int64 = 0

        static let ticksPerMillisecond: Int64 = 10_000
        static let ticksPerSecond: Int64 = 10_000_000
        static let ticksPerDay: Int64 = 864_000_000_000
        static let minValue = CadDateTime(ticks: 0)
        static let maxTicks: Int64 = 3_155_378_975_999_999_999

        init(ticks: Int64 = 0) { self.ticks = ticks }

        /// `new DateTime(year, month, day, hour, minute, second, millisecond)`; nil when out of range.
        init?(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, _ millisecond: Int = 0) {
            guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
                  day <= CadDateTime.daysInMonth(year, month), (0..<24).contains(hour), (0..<60).contains(minute),
                  (0..<60).contains(second), (0..<1000).contains(millisecond) else { return nil }
            let days = CadDateTime.daysFromCivil(year, month, day)
            ticks = days * CadDateTime.ticksPerDay
                + Int64(hour) * 36_000_000_000 + Int64(minute) * 600_000_000 + Int64(second) * CadDateTime.ticksPerSecond
                + Int64(millisecond) * CadDateTime.ticksPerMillisecond
        }

        static func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
        static func daysInMonth(_ y: Int, _ m: Int) -> Int {
            [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        }

        /// Days since 0001-01-01 (proleptic Gregorian).
        static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
            let y1 = Int64(y - 1)
            var days = y1 * 365 + y1 / 4 - y1 / 100 + y1 / 400
            for month in 1..<m { days += Int64(daysInMonth(y, month)) }
            return days + Int64(d - 1)
        }

        var components: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int) {
            var n = ticks / CadDateTime.ticksPerDay
            let y400 = n / 146_097; n -= y400 * 146_097
            var y100 = n / 36_524; if y100 == 4 { y100 = 3 }; n -= y100 * 36_524
            let y4 = n / 1_461; n -= y4 * 1_461
            var y1 = n / 365; if y1 == 4 { y1 = 3 }; n -= y1 * 365
            let year = Int(y400 * 400 + y100 * 100 + y4 * 4 + y1 + 1)
            var month = 1
            var rest = Int(n)
            while rest >= CadDateTime.daysInMonth(year, month) {
                rest -= CadDateTime.daysInMonth(year, month)
                month += 1
            }
            let time = ticks % CadDateTime.ticksPerDay
            return (year, month, rest + 1, Int(time / 36_000_000_000), Int(time / 600_000_000 % 60),
                    Int(time / CadDateTime.ticksPerSecond % 60), Int(time / CadDateTime.ticksPerMillisecond % 1000))
        }

        /// `AddSeconds` / `AddMilliseconds` (.NET 7+: whole units, the fraction truncated to ticks); nil on overflow.
        func adding(seconds: Double) -> CadDateTime? { adding(units: seconds, scale: CadDateTime.ticksPerSecond) }
        func adding(milliseconds: Double) -> CadDateTime? { adding(units: milliseconds, scale: CadDateTime.ticksPerMillisecond) }

        private func adding(units: Double, scale: Int64) -> CadDateTime? {
            let integral = units.rounded(.towardZero)
            let fraction = units - integral
            guard abs(integral) < Double(Int64.max / scale) else { return nil }
            let delta = Int64(integral) * scale + Int64(fraction * Double(scale))
            let result = ticks.addingReportingOverflow(delta)
            guard !result.overflow, result.partialValue >= 0, result.partialValue <= CadDateTime.maxTicks else { return nil }
            return CadDateTime(ticks: result.partialValue)
        }

        private static func from(_ date: Date, _ zone: TimeZone) -> CadDateTime {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            var value = CadDateTime(c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!) ?? CadDateTime()
            value.ticks += Int64(c.nanosecond! / 100)
            return value
        }

        static func now() -> CadDateTime { from(Date(), .current) }
        static func utcNow() -> CadDateTime { from(Date(), TimeZone(identifier: "UTC")!) }

        /// `CadUtils.ToJulianCalendar`.
        var julian: Double {
            let c = components
            var year = c.year, month = c.month
            let fraction = Double(c.day) + Double(c.hour) / 24.0 + Double(c.minute) / 1440.0
                + (Double(c.second) + Double(c.millisecond) / 1000) / 86400.0
            if month < 3 {
                year -= 1
                month += 12
            }
            let a = year / 100
            let b = 2 - a + a / 4
            let cc = year < 0 ? Int(365.25 * Double(year) - 0.75) : Int(365.25 * Double(year))
            let d = Int(30.6001 * Double(month + 1))
            return Double(b + cc + d + 1_720_995) + fraction
        }

        /// `CadUtils.FromJulianCalendar`; nil outside 0001 … 9999.
        static func fromJulian(_ date: Double) -> CadDateTime? {
            guard date >= 1_721_426, date <= 5_373_484 else { return nil }
            var julian = Double(Int(date))
            var fraction = date - julian
            let temp = Int((julian - 1_867_216.25) / 36_524.25)
            julian = julian + 1 + Double(temp) - Double(Int(Double(temp) / 4.0))
            let a = Int(julian) + 1524
            let b = Int((Double(a) - 122.1) / 365.25)
            let c = Int(365.25 * Double(b))
            let d = Int(Double(a - c) / 30.6001)
            let months = d < 14 ? d - 1 : d - 13
            let years = months > 2 ? b - 4716 : b - 4715
            let days = a - c - Int(30.6001 * Double(d))
            let hours = Int(fraction * 24)
            fraction -= Double(hours) / 24.0
            let minutes = Int(fraction * 1440)
            fraction -= Double(minutes) / 1440.0
            let decimalSeconds = fraction * 86400
            let seconds = Int(decimalSeconds)
            let milliseconds = Int((decimalSeconds - Double(seconds)) * 1000)
            return CadDateTime(years, months, days, hours, minutes, seconds, milliseconds)
        }

        /// The DWG reader's `julianToDate`: 1970-01-01 plus (jdate − 2440587.5) days (MinValue when that overflows),
        /// then the milliseconds, which throw when they leave the DateTime range.
        static func fromDwg(jdate: Int32, milliseconds: Int32) throws -> CadDateTime {
            let unix = (Double(jdate) - 2_440_587.5) * 86400
            let date = CadDateTime(1970, 1, 1)!.adding(seconds: unix) ?? .minValue
            guard let result = date.adding(milliseconds: Double(milliseconds)) else {
                throw DwgError("The added or subtracted value results in an un-representable DateTime. (Parameter 'value')")
            }
            return result
        }

        /// `CadUtils.DateToJulian` for the DWG writer.
        var dwgJulian: (jdate: Int32, milliseconds: Int32) {
            guard ticks >= 432_000_000_000 else { return (0, 0) } // 0001-01-01 12:00
            let shifted = CadDateTime(ticks: ticks - 432_000_000_000)
            let c = shifted.components
            let day = Int(floor((14.0 - Double(c.month)) / 12.0))
            let year = c.year + 4800 - day
            let month = c.month
            let jdate = c.day + Int(floor((153.0 * Double(month + 12 * day - 3) + 2.0) / 5.0)) + 365 * year
                + Int(floor(Double(year) / 4.0)) - Int(floor(Double(year) / 100.0)) + Int(floor(Double(year) / 400.0)) - 32045
            let ms = c.millisecond + c.second * 1000 + c.minute * 60000 + c.hour * 3_600_000
            return (Int32(truncatingIfNeeded: jdate), Int32(truncatingIfNeeded: ms))
        }
    }

    /// .NET `TimeSpan` (ticks of 100 ns).
    struct CadTimeSpan: Hashable {
        var ticks: Int64 = 0

        var totalDays: Double { Double(ticks) / Double(CadDateTime.ticksPerDay) }
        var totalHours: Double { Double(ticks) / 36_000_000_000 }

        /// `CadUtils.EditingTime`: days with the fraction truncated to whole milliseconds.
        static func editingTime(_ elapsed: Double) -> CadTimeSpan {
            let days = Int64(elapsed)
            var fraction = elapsed - Double(days)
            let hours = Int64(fraction * 24)
            fraction -= Double(hours) / 24.0
            let minutes = Int64(fraction * 1440)
            fraction -= Double(minutes) / 1440.0
            let decimalSeconds = fraction * 86400
            let seconds = Int64(decimalSeconds)
            let milliseconds = Int64((decimalSeconds - Double(seconds)) * 1000)
            return CadTimeSpan(ticks: ((((days * 24 + hours) * 60 + minutes) * 60 + seconds) * 1000 + milliseconds) * 10_000)
        }

        /// The DWG reader's `ReadTimeSpan`: hours and milliseconds.
        static func fromDwg(hours: Int32, milliseconds: Int32) -> CadTimeSpan {
            if hours < 0 || milliseconds < 0 { return CadTimeSpan() }
            return CadTimeSpan(ticks: Int64(hours) * 36_000_000_000 + Int64(milliseconds) * 10_000)
        }
    }

    /// `CadHeader`.
    final class CadHeader {
        weak var document: Document?

        /// Dimension variables live in an override style (`DimensionstyleOverrides`), like ACadSharp.
        let dimensionStyleOverrides = DimensionStyle(name: "override")

        var version: Version = .ac1032 {
            didSet { maintenanceVersion = CadHeader.maintenance(for: version) }
        }

        /// ACADMAINTVER as the DWG writer writes it, per version.
        var maintenanceVersion: Int16 = 228

        static func maintenance(for version: Version) -> Int16 {
            switch version {
            case .ac1015: return 20
            case .ac1018: return 104
            case .ac1021: return 50
            case .ac1024: return 226
            case .ac1027: return 125
            case .ac1032: return 228
            default: return 0
            }
        }

        /// `$ACADVER`.
        var versionString: String {
            get { String(describing: version).uppercased() == "UNKNOWN" ? "Unknown" : version.name }
            set { version = Version.from(name: newValue) }
        }

        // DWG-only values (no DXF variable).
        var intersectionDisplay: UInt8 = 0
        var loadOLEObject = false
        var obscuredColor = Color.byBlock
        var obscuredType: UInt8 = 0
        var stackedTextAlignment: Int16 = 1
        var stackedTextSizePercentage: Int16 = 70
        var textQuality: Int16 = 50
        var surfaceIsolineCount: Int16 = 4
        var dimsav = false

        init(version: Version = .ac1032) {
            self.version = version
            maintenanceVersion = CadHeader.maintenance(for: version)
        }

    // ── Generated from ACadSharp CadHeader.cs (3.8): one property per $VARIABLE, in declaration order. ──
    var angleBase: Double = 0.0
    var angularDirection: Int16 = 1
    var angularUnit: Int16 = 0
    var angularUnitPrecision: Int16 = 0
    var arrowBlockName: String = ""
    var associatedDimensions: Bool = true
    var attributeVisibility: Int32 = 1
    var blipMode: Bool = false
    var cameraDisplayObjects: Bool = false
    var cameraHeight: Double = 0.0
    var chamferAngle: Double = 0.0
    var chamferDistance1: Double = 0.0
    var chamferDistance2: Double = 0.0
    var chamferLength: Double = 0.0
    var codePage: String? = "ANSI_1252"
    var createDateTime: CadDateTime = CadDateTime.now()
    var createEllipseAsPolyline: Bool = false
    var currentDimensionStyleName: String = "Standard"
    var currentEntityColor: Color = .byLayer
    var currentEntityLinetypeScale: Double = 1.0
    var currentEntityLineWeight: LineWeight = .byLayer
    var currentEntityPlotStyle: Int16 = 0
    var currentLayerName: String = "0"
    var currentLineTypeName: String = "ByLayer"
    var currentMLineStyleName: String = "Standard"
    var currentMultiLineJustification: Int16 = 0
    var currentMultilineScale: Double = 20.0
    var currentTextStyleName: String = "Standard"
    var dgnUnderlayFramesVisibility: UInt16 = 0
    var dimensionAlternateDimensioningSuffix: String { get { dimensionStyleOverrides.alternateDimensioningSuffix } set { dimensionStyleOverrides.alternateDimensioningSuffix = newValue } }
    var dimensionAlternateUnitDecimalPlaces: Int16 { get { dimensionStyleOverrides.alternateUnitDecimalPlaces } set { dimensionStyleOverrides.alternateUnitDecimalPlaces = newValue } }
    var dimensionAlternateUnitDimensioning: Bool { get { dimensionStyleOverrides.alternateUnitDimensioning } set { dimensionStyleOverrides.alternateUnitDimensioning = newValue } }
    var dimensionAlternateUnitFormat: Int16 { get { dimensionStyleOverrides.alternateUnitFormat } set { dimensionStyleOverrides.alternateUnitFormat = newValue } }
    var dimensionAlternateUnitRounding: Double { get { dimensionStyleOverrides.alternateUnitRounding } set { dimensionStyleOverrides.alternateUnitRounding = newValue } }
    var dimensionAlternateUnitScaleFactor: Double { get { dimensionStyleOverrides.alternateUnitScaleFactor } set { dimensionStyleOverrides.alternateUnitScaleFactor = newValue } }
    var dimensionAlternateUnitToleranceDecimalPlaces: Int16 { get { dimensionStyleOverrides.alternateUnitToleranceDecimalPlaces } set { dimensionStyleOverrides.alternateUnitToleranceDecimalPlaces = newValue } }
    var dimensionAlternateUnitToleranceZeroHandling: UInt8 { get { dimensionStyleOverrides.alternateUnitToleranceZeroHandling } set { dimensionStyleOverrides.alternateUnitToleranceZeroHandling = newValue } }
    var dimensionAlternateUnitZeroHandling: UInt8 { get { dimensionStyleOverrides.alternateUnitZeroHandling } set { dimensionStyleOverrides.alternateUnitZeroHandling = newValue } }
    var dimensionAltMzf: Double { get { dimensionStyleOverrides.altMzf } set { dimensionStyleOverrides.altMzf = newValue } }
    var dimensionAltMzs: String { get { dimensionStyleOverrides.altMzs } set { dimensionStyleOverrides.altMzs = newValue } }
    var dimensionAngularDimensionDecimalPlaces: Int16 { get { dimensionStyleOverrides.angularDecimalPlaces } set { dimensionStyleOverrides.angularDecimalPlaces = newValue } }
    var dimensionAngularUnit: Int16 { get { dimensionStyleOverrides.angularUnit } set { dimensionStyleOverrides.angularUnit = newValue } }
    var dimensionAngularZeroHandling: UInt8 { get { dimensionStyleOverrides.angularZeroHandling } set { dimensionStyleOverrides.angularZeroHandling = newValue } }
    var dimensionArcLengthSymbolPosition: Int16 { get { dimensionStyleOverrides.arcLengthSymbolPosition } set { dimensionStyleOverrides.arcLengthSymbolPosition = newValue } }
    var dimensionArrowSize: Double { get { dimensionStyleOverrides.arrowSize } set { dimensionStyleOverrides.arrowSize = newValue } }
    var dimensionAssociativity: Int16 = 2
    var dimensionBlockName: String = ""
    var dimensionBlockNameFirst: String? = nil
    var dimensionBlockNameSecond: String? = nil
    var dimensionCenterMarkSize: Double { get { dimensionStyleOverrides.centerMarkSize } set { dimensionStyleOverrides.centerMarkSize = newValue } }
    var dimensionCursorUpdate: Bool { get { dimensionStyleOverrides.cursorUpdate } set { dimensionStyleOverrides.cursorUpdate = newValue } }
    var dimensionDecimalPlaces: Int16 { get { dimensionStyleOverrides.decimalPlaces } set { dimensionStyleOverrides.decimalPlaces = newValue } }
    var dimensionDecimalSeparator: UInt16 { get { dimensionStyleOverrides.decimalSeparator } set { dimensionStyleOverrides.decimalSeparator = newValue } }
    var dimensionDimensionTextArrowFit: UInt8 { get { dimensionStyleOverrides.dimensionTextArrowFit } set { dimensionStyleOverrides.dimensionTextArrowFit = newValue } }
    var dimensionExtensionLineColor: Color { get { dimensionStyleOverrides.extensionLineColor } set { dimensionStyleOverrides.extensionLineColor = newValue } }
    var dimensionExtensionLineExtension: Double { get { dimensionStyleOverrides.extensionLineExtension } set { dimensionStyleOverrides.extensionLineExtension = newValue } }
    var dimensionExtensionLineOffset: Double { get { dimensionStyleOverrides.extensionLineOffset } set { dimensionStyleOverrides.extensionLineOffset = newValue } }
    var dimensionFit: Int16 { get { dimensionStyleOverrides.dimensionFit } set { dimensionStyleOverrides.dimensionFit = newValue } }
    var dimensionFixedExtensionLineLength: Double { get { dimensionStyleOverrides.fixedExtensionLineLength } set { dimensionStyleOverrides.fixedExtensionLineLength = newValue } }
    var dimensionFractionFormat: Int16 { get { dimensionStyleOverrides.fractionFormat } set { dimensionStyleOverrides.fractionFormat = newValue } }
    var dimensionGenerateTolerances: Bool { get { dimensionStyleOverrides.generateTolerances } set { dimensionStyleOverrides.generateTolerances = newValue } }
    var dimensionIsExtensionLineLengthFixed: Bool { get { dimensionStyleOverrides.isExtensionLineLengthFixed } set { dimensionStyleOverrides.isExtensionLineLengthFixed = newValue } }
    var dimensionJoggedRadiusDimensionTransverseSegmentAngle: Double { get { dimensionStyleOverrides.joggedRadiusDimensionTransverseSegmentAngle } set { dimensionStyleOverrides.joggedRadiusDimensionTransverseSegmentAngle = newValue } }
    var dimensionLimitsGeneration: Bool { get { dimensionStyleOverrides.limitsGeneration } set { dimensionStyleOverrides.limitsGeneration = newValue } }
    var dimensionLinearScaleFactor: Double { get { dimensionStyleOverrides.linearScaleFactor } set { dimensionStyleOverrides.linearScaleFactor = newValue } }
    var dimensionLinearUnitFormat: Int16 { get { dimensionStyleOverrides.linearUnitFormat } set { dimensionStyleOverrides.linearUnitFormat = newValue } }
    var dimensionLineColor: Color { get { dimensionStyleOverrides.dimensionLineColor } set { dimensionStyleOverrides.dimensionLineColor = newValue } }
    var dimensionLineExtension: Double { get { dimensionStyleOverrides.dimensionLineExtension } set { dimensionStyleOverrides.dimensionLineExtension = newValue } }
    var dimensionLineGap: Double { get { dimensionStyleOverrides.dimensionLineGap } set { dimensionStyleOverrides.dimensionLineGap = newValue } }
    var dimensionLineIncrement: Double { get { dimensionStyleOverrides.dimensionLineIncrement } set { dimensionStyleOverrides.dimensionLineIncrement = newValue } }
    var dimensionLineType: String = "ByBlock"
    var dimensionLineWeight: LineWeight { get { dimensionStyleOverrides.dimensionLineWeight } set { dimensionStyleOverrides.dimensionLineWeight = newValue } }
    var dimensionMinusTolerance: Double { get { dimensionStyleOverrides.minusTolerance } set { dimensionStyleOverrides.minusTolerance = newValue } }
    var dimensionMzf: Double { get { dimensionStyleOverrides.mzf } set { dimensionStyleOverrides.mzf = newValue } }
    var dimensionMzs: String { get { dimensionStyleOverrides.mzs } set { dimensionStyleOverrides.mzs = newValue } }
    var dimensionPlusTolerance: Double { get { dimensionStyleOverrides.plusTolerance } set { dimensionStyleOverrides.plusTolerance = newValue } }
    var dimensionPostFix: String { get { dimensionStyleOverrides.postFix } set { dimensionStyleOverrides.postFix = newValue } }
    var dimensionRounding: Double { get { dimensionStyleOverrides.rounding } set { dimensionStyleOverrides.rounding = newValue } }
    var dimensionScaleFactor: Double { get { dimensionStyleOverrides.scaleFactor } set { dimensionStyleOverrides.scaleFactor = newValue } }
    var dimensionSeparateArrowBlocks: Bool { get { dimensionStyleOverrides.separateArrowBlocks } set { dimensionStyleOverrides.separateArrowBlocks = newValue } }
    var dimensionSuppressFirstDimensionLine: Bool { get { dimensionStyleOverrides.suppressFirstDimensionLine } set { dimensionStyleOverrides.suppressFirstDimensionLine = newValue } }
    var dimensionSuppressFirstExtensionLine: Bool { get { dimensionStyleOverrides.suppressFirstExtensionLine } set { dimensionStyleOverrides.suppressFirstExtensionLine = newValue } }
    var dimensionSuppressOutsideExtensions: Bool { get { dimensionStyleOverrides.suppressOutsideExtensions } set { dimensionStyleOverrides.suppressOutsideExtensions = newValue } }
    var dimensionSuppressSecondDimensionLine: Bool { get { dimensionStyleOverrides.suppressSecondDimensionLine } set { dimensionStyleOverrides.suppressSecondDimensionLine = newValue } }
    var dimensionSuppressSecondExtensionLine: Bool { get { dimensionStyleOverrides.suppressSecondExtensionLine } set { dimensionStyleOverrides.suppressSecondExtensionLine = newValue } }
    var dimensionTex1: String = "ByBlock"
    var dimensionTex2: String = "ByBlock"
    var dimensionTextBackgroundColor: Color { get { dimensionStyleOverrides.textBackgroundColor } set { dimensionStyleOverrides.textBackgroundColor = newValue } }
    var dimensionTextBackgroundFillMode: Int16 { get { dimensionStyleOverrides.textBackgroundFillMode } set { dimensionStyleOverrides.textBackgroundFillMode = newValue } }
    var dimensionTextColor: Color { get { dimensionStyleOverrides.textColor } set { dimensionStyleOverrides.textColor = newValue } }
    var dimensionTextDirection: UInt8 { get { dimensionStyleOverrides.textDirection } set { dimensionStyleOverrides.textDirection = newValue } }
    var dimensionTextHeight: Double { get { dimensionStyleOverrides.textHeight } set { dimensionStyleOverrides.textHeight = newValue } }
    var dimensionTextHorizontalAlignment: UInt8 { get { dimensionStyleOverrides.textHorizontalAlignment } set { dimensionStyleOverrides.textHorizontalAlignment = newValue } }
    var dimensionTextInsideExtensions: Bool { get { dimensionStyleOverrides.textInsideExtensions } set { dimensionStyleOverrides.textInsideExtensions = newValue } }
    var dimensionTextInsideHorizontal: Bool { get { dimensionStyleOverrides.textInsideHorizontal } set { dimensionStyleOverrides.textInsideHorizontal = newValue } }
    var dimensionTextMovement: Int16 { get { dimensionStyleOverrides.textMovement } set { dimensionStyleOverrides.textMovement = newValue } }
    var dimensionTextOutsideExtensions: Bool { get { dimensionStyleOverrides.textOutsideExtensions } set { dimensionStyleOverrides.textOutsideExtensions = newValue } }
    var dimensionTextOutsideHorizontal: Bool { get { dimensionStyleOverrides.textOutsideHorizontal } set { dimensionStyleOverrides.textOutsideHorizontal = newValue } }
    var dimensionTextStyleName: String = "Standard"
    var dimensionTextVerticalAlignment: Int32 { get { dimensionStyleOverrides.textVerticalAlignment } set { dimensionStyleOverrides.textVerticalAlignment = newValue } }
    var dimensionTextVerticalPosition: Double { get { dimensionStyleOverrides.textVerticalPosition } set { dimensionStyleOverrides.textVerticalPosition = newValue } }
    var dimensionTickSize: Double { get { dimensionStyleOverrides.tickSize } set { dimensionStyleOverrides.tickSize = newValue } }
    var dimensionToleranceAlignment: UInt8 { get { dimensionStyleOverrides.toleranceAlignment } set { dimensionStyleOverrides.toleranceAlignment = newValue } }
    var dimensionToleranceDecimalPlaces: Int16 { get { dimensionStyleOverrides.toleranceDecimalPlaces } set { dimensionStyleOverrides.toleranceDecimalPlaces = newValue } }
    var dimensionToleranceScaleFactor: Double { get { dimensionStyleOverrides.toleranceScaleFactor } set { dimensionStyleOverrides.toleranceScaleFactor = newValue } }
    var dimensionToleranceZeroHandling: UInt8 { get { dimensionStyleOverrides.toleranceZeroHandling } set { dimensionStyleOverrides.toleranceZeroHandling = newValue } }
    var dimensionUnit: Int16 { get { dimensionStyleOverrides.dimensionUnit } set { dimensionStyleOverrides.dimensionUnit = newValue } }
    var dimensionZeroHandling: UInt8 { get { dimensionStyleOverrides.zeroHandling } set { dimensionStyleOverrides.zeroHandling = newValue } }
    var displayLightGlyphs: UInt16 = 0
    var displayLineWeight: Bool = false
    var displaySilhouetteCurves: Bool = false
    var draftAngleFirstCrossSection: Double = 0.0
    var draftAngleSecondCrossSection: Double = 0.0
    var draftMagnitudeFirstCrossSection: Double = 0.0
    var draftMagnitudeSecondCrossSection: Double = 0.0
    var dw3DPrecision: Double = 0.0
    var dwgUnderlayFramesVisibility: UInt16 = 0
    var elevation: Double = 0.0
    var endCaps: Int16 = 0
    var entitySortingFlags: UInt8 = 0
    var extendedNames: Bool = true
    var extensionLineWeight: LineWeight { get { dimensionStyleOverrides.extensionLineWeight } set { dimensionStyleOverrides.extensionLineWeight = newValue } }
    var externalReferenceClippingBoundaryType: Int32 = 2
    var facetResolution: Double = 0.5
    var filletRadius: Double = 0.0
    var fillMode: Bool = true
    var fingerPrintGuid: String = UUID().uuidString.lowercased()
    var haloGapPercentage: UInt8 = 0
    var handleSeed: UInt64 = 1
    var hideText: UInt8 = 0
    var hyperLinkBase: String? = nil
    var indexCreationFlags: UInt8 = 0
    var insUnits: Int16 = 0
    var interfereColor: Color = Color(index: 1)
    var joinStyle: Int16 = 0
    var lastSavedBy: String = "ACadSharp"
    var latitude: Double = 37.7950
    var lensLength: Double = 0.0
    var limitCheckingOn: Bool = false
    var linearUnitFormat: Int16 = 2
    var linearUnitPrecision: Int16 = 4
    var lineTypeScale: Double = 1.0
    var loftedObjectNormals: UInt16 = 0
    var longitude: Double = -122.394
    var maxViewportCount: Int16 = 64
    var measurementUnits: Int16 = 1
    var menuFileName: String = "."
    var mirrorText: Bool = false
    var modelSpaceExtMax: XYZ = .zero
    var modelSpaceExtMin: XYZ = .zero
    var modelSpaceInsertionBase: XYZ = .zero
    var modelSpaceLimitsMax: XY = .zero
    var modelSpaceLimitsMin: XY = .zero
    var modelSpaceOrigin: XYZ = .zero
    var modelSpaceOrthographicBackDOrigin: XYZ = .zero
    var modelSpaceOrthographicBottomDOrigin: XYZ = .zero
    var modelSpaceOrthographicFrontDOrigin: XYZ = .zero
    var modelSpaceOrthographicLeftDOrigin: XYZ = .zero
    var modelSpaceOrthographicRightDOrigin: XYZ = .zero
    var modelSpaceOrthographicTopDOrigin: XYZ = .zero
    var modelSpaceXAxis: XYZ = .axisX // ModelSpaceUcs.XAxis
    var modelSpaceYAxis: XYZ = .axisY
    var northDirection: Double = 0.0
    var numberOfSplineSegments: Int16 = 8
    var objectSnapMode: UInt16 = 4133
    var orthoMode: Bool = false
    var paperSpaceBaseName: String = ""
    var paperSpaceElevation: Double = 0.0
    var paperSpaceExtMax: XYZ = .zero
    var paperSpaceExtMin: XYZ = .zero
    var paperSpaceInsertionBase: XYZ = .zero
    var paperSpaceLimitsChecking: Bool = false
    var paperSpaceLimitsMax: XY = .zero
    var paperSpaceLimitsMin: XY = .zero
    var paperSpaceLineTypeScaling: Int16 = 1
    var paperSpaceName: String = ""
    var paperSpaceOrthographicBackDOrigin: XYZ = .zero
    var paperSpaceOrthographicBottomDOrigin: XYZ = .zero
    var paperSpaceOrthographicFrontDOrigin: XYZ = .zero
    var paperSpaceOrthographicLeftDOrigin: XYZ = .zero
    var paperSpaceOrthographicRightDOrigin: XYZ = .zero
    var paperSpaceOrthographicTopDOrigin: XYZ = .zero
    var paperSpaceUcsOrigin: XYZ = .zero
    var paperSpaceUcsXAxis: XYZ = .axisX // PaperSpaceUcs.XAxis
    var paperSpaceUcsYAxis: XYZ = .axisY
    var plotStyleMode: Int16 = 0
    var pointDisplayMode: Int16 = 0
    var pointDisplaySize: Double = 0.0
    var polylineLineTypeGeneration: Bool = false
    var polylineWidthDefault: Double = 0.0
    var projectName: String? = nil
    var proxyGraphics: Bool = true
    var quickTextMode: Bool = false
    var regenerationMode: Bool = true
    var requiredVersions: Int64 = 0
    var retainXRefDependentVisibilitySettings: Bool = true
    var shadeDiffuseToAmbientPercentage: Int16 = 70
    var shadeEdge: Int16 = 3
    var shadowMode: UInt8 = 0
    var shadowPlaneLocation: Double = 0.0
    var showModelSpace: Bool = true
    var showSolidsHistory: UInt16 = 0
    var showSplineControlPoints: Bool = false
    var sketchIncrement: Double = 1.0
    var sketchPolylines: Bool = false
    var solidLoftedShape: Int16 = 0
    var solidsRetainHistory: UInt16 = 0
    var spatialIndexMaxTreeDepth: Int16 = 3020
    var splineType: Int16 = 6
    var stepSize: Double = 6.0
    var stepsPerSecond: Double = 2.0
    var styleSheetName: String? = nil
    var surfaceDensityU: Int16 = 6
    var surfaceDensityV: Int16 = 6
    var surfaceMeshTabulationCount1: Int16 = 6
    var surfaceMeshTabulationCount2: Int16 = 6
    var surfaceType: Int16 = 6
    var sweptSolidHeight: Double = 0.0
    var sweptSolidWidth: Double = 0.0
    var textHeightDefault: Double = 2.5
    var thicknessDefault: Double = 0.0
    var timeZone: Int32 = 0
    var totalEditingTime: CadTimeSpan = CadTimeSpan()
    var traceWidthDefault: Double = 0.0
    var ucsBaseName: String = ""
    var ucsName: String = ""
    var unitMode: Int16 = 0
    var universalCreateDateTime: CadDateTime = CadDateTime.utcNow()
    var universalUpdateDateTime: CadDateTime = CadDateTime.utcNow()
    var updateDateTime: CadDateTime = CadDateTime.now()
    var updateDimensionsWhileDragging: Bool = true
    var userDouble1: Double = 0.0
    var userDouble2: Double = 0.0
    var userDouble3: Double = 0.0
    var userDouble4: Double = 0.0
    var userDouble5: Double = 0.0
    var userElapsedTimeSpan: CadTimeSpan = CadTimeSpan()
    var userShort1: Int16 = 0
    var userShort2: Int16 = 0
    var userShort3: Int16 = 0
    var userShort4: Int16 = 0
    var userShort5: Int16 = 0
    var userTimer: Bool = false
    var versionGuid: String = UUID().uuidString.lowercased()
    var viewportDefaultViewScaleFactor: Double = 0.0
    var worldView: Bool = true
    var xEdit: Bool = false

        // ───────────────────────── Variable map ─────────────────────────

        /// A typed accessor of one header property.
        enum Accessor {
            case double(ReferenceWritableKeyPath<CadHeader, Double>)
            case int16(ReferenceWritableKeyPath<CadHeader, Int16>)
            case uint16(ReferenceWritableKeyPath<CadHeader, UInt16>)
            case int32(ReferenceWritableKeyPath<CadHeader, Int32>)
            case int64(ReferenceWritableKeyPath<CadHeader, Int64>)
            case uint8(ReferenceWritableKeyPath<CadHeader, UInt8>)
            case uint64(ReferenceWritableKeyPath<CadHeader, UInt64>)
            case bool(ReferenceWritableKeyPath<CadHeader, Bool>)
            case string(ReferenceWritableKeyPath<CadHeader, String>)
            case optionalString(ReferenceWritableKeyPath<CadHeader, String?>)
            case xyz(ReferenceWritableKeyPath<CadHeader, XYZ>)
            case xy(ReferenceWritableKeyPath<CadHeader, XY>)
            case color(ReferenceWritableKeyPath<CadHeader, Color>)
            case lineWeight(ReferenceWritableKeyPath<CadHeader, LineWeight>)
            case date(ReferenceWritableKeyPath<CadHeader, CadDateTime>)
            case timeSpan(ReferenceWritableKeyPath<CadHeader, CadTimeSpan>)
        }

        /// One `CadSystemVariable`: its DXF name, group codes and property.
        struct Variable {
            let name: String
            let codes: [Int]
            let isName: Bool
            let ignored: Bool
            let range: ClosedRange<Double>?
            let accessor: Accessor

            init(_ name: String, _ codes: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil,
                 _ accessor: Accessor) {
                self.name = name
                self.codes = codes
                self.isName = isName
                self.ignored = ignored
                self.range = range
                self.accessor = accessor
            }

            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, Double>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.double(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, Int16>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.int16(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, UInt16>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.uint16(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, Int32>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.int32(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, Int64>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.int64(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, UInt8>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.uint8(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, UInt64>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.uint64(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, Bool>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.bool(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, String>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.string(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, String?>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.optionalString(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, XYZ>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.xyz(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, XY>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.xy(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, Color>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.color(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, LineWeight>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.lineWeight(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, CadDateTime>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.date(p)) }
            init(_ n: String, _ c: [Int], isName: Bool = false, ignored: Bool = false, range: ClosedRange<Double>? = nil, _ p: ReferenceWritableKeyPath<CadHeader, CadTimeSpan>) { self.init(n, c, isName: isName, ignored: ignored, range: range, Accessor.timeSpan(p)) }
        }

        static let variablesByName: [String: Variable] = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0) })

        /// The system variable map (`CadHeader.GetHeaderMap`), in property order.
        static let variables: [Variable] = [
        Variable("$ANGBASE", [50], \.angleBase),
        Variable("$ANGDIR", [70], \.angularDirection),
        Variable("$AUNITS", [70], \.angularUnit),
        Variable("$AUPREC", [70], range: 0...8, \.angularUnitPrecision),
        Variable("$DIMLDRBLK", [1], \.arrowBlockName),
        Variable("$DIMASO", [70], \.associatedDimensions),
        Variable("$ATTMODE", [70], \.attributeVisibility),
        Variable("$BLIPMODE", [70], \.blipMode),
        Variable("$CAMERADISPLAY", [290], \.cameraDisplayObjects),
        Variable("$CAMERAHEIGHT", [40], \.cameraHeight),
        Variable("$CHAMFERD", [40], \.chamferAngle),
        Variable("$CHAMFERA", [40], \.chamferDistance1),
        Variable("$CHAMFERB", [40], \.chamferDistance2),
        Variable("$CHAMFERC", [40], \.chamferLength),
        Variable("$DWGCODEPAGE", [3], \.codePage),
        Variable("$TDCREATE", [40], \.createDateTime),
        Variable("$PELLIPSE", [70], \.createEllipseAsPolyline),
        Variable("$DIMSTYLE", [2], isName: true, \.currentDimensionStyleName),
        Variable("$CECOLOR", [62], \.currentEntityColor),
        Variable("$CELTSCALE", [40], \.currentEntityLinetypeScale),
        Variable("$CELWEIGHT", [370], \.currentEntityLineWeight),
        Variable("$CEPSNTYPE", [380], \.currentEntityPlotStyle),
        Variable("$CLAYER", [8], isName: true, \.currentLayerName),
        Variable("$CELTYPE", [6], isName: true, \.currentLineTypeName),
        Variable("$CMLSTYLE", [2], isName: true, \.currentMLineStyleName),
        Variable("$CMLJUST", [70], \.currentMultiLineJustification),
        Variable("$CMLSCALE", [40], \.currentMultilineScale),
        Variable("$TEXTSTYLE", [7], isName: true, \.currentTextStyleName),
        Variable("$DGNFRAME", [280], \.dgnUnderlayFramesVisibility),
        Variable("$DIMAPOST", [1], \.dimensionAlternateDimensioningSuffix),
        Variable("$DIMALTD", [70], \.dimensionAlternateUnitDecimalPlaces),
        Variable("$DIMALT", [70], \.dimensionAlternateUnitDimensioning),
        Variable("$DIMALTU", [70], \.dimensionAlternateUnitFormat),
        Variable("$DIMALTRND", [40], \.dimensionAlternateUnitRounding),
        Variable("$DIMALTF", [40], \.dimensionAlternateUnitScaleFactor),
        Variable("$DIMALTTD", [70], \.dimensionAlternateUnitToleranceDecimalPlaces),
        Variable("$DIMALTTZ", [70], \.dimensionAlternateUnitToleranceZeroHandling),
        Variable("$DIMALTZ", [70], \.dimensionAlternateUnitZeroHandling),
        Variable("$DIMALTMZF", [40], \.dimensionAltMzf),
        Variable("$DIMALTMZS", [6], \.dimensionAltMzs),
        Variable("$DIMADEC", [70], \.dimensionAngularDimensionDecimalPlaces),
        Variable("$DIMAUNIT", [70], \.dimensionAngularUnit),
        Variable("$DIMAZIN", [70], \.dimensionAngularZeroHandling),
        Variable("$DIMARCSYM", [70], \.dimensionArcLengthSymbolPosition),
        Variable("$DIMASZ", [40], \.dimensionArrowSize),
        Variable("$DIMASSOC", [280], \.dimensionAssociativity),
        Variable("$DIMBLK", [1], \.dimensionBlockName),
        Variable("$DIMBLK1", [1], \.dimensionBlockNameFirst),
        Variable("$DIMBLK2", [1], \.dimensionBlockNameSecond),
        Variable("$DIMCEN", [40], \.dimensionCenterMarkSize),
        Variable("$DIMUPT", [70], \.dimensionCursorUpdate),
        Variable("$DIMDEC", [70], \.dimensionDecimalPlaces),
        Variable("$DIMDSEP", [70], \.dimensionDecimalSeparator),
        Variable("$DIMATFIT", [70], \.dimensionDimensionTextArrowFit),
        Variable("$DIMCLRE", [70], \.dimensionExtensionLineColor),
        Variable("$DIMEXE", [40], \.dimensionExtensionLineExtension),
        Variable("$DIMEXO", [40], \.dimensionExtensionLineOffset),
        Variable("$DIMFIT", [70], \.dimensionFit),
        Variable("$DIMFXL", [40], \.dimensionFixedExtensionLineLength),
        Variable("$DIMFRAC", [70], \.dimensionFractionFormat),
        Variable("$DIMTOL", [70], \.dimensionGenerateTolerances),
        Variable("$DIMFXLON", [70], \.dimensionIsExtensionLineLengthFixed),
        Variable("$DIMJOGANG", [40], \.dimensionJoggedRadiusDimensionTransverseSegmentAngle),
        Variable("$DIMLIM", [70], \.dimensionLimitsGeneration),
        Variable("$DIMLFAC", [40], \.dimensionLinearScaleFactor),
        Variable("$DIMLUNIT", [70], \.dimensionLinearUnitFormat),
        Variable("$DIMCLRD", [70], \.dimensionLineColor),
        Variable("$DIMDLE", [40], \.dimensionLineExtension),
        Variable("$DIMGAP", [40], \.dimensionLineGap),
        Variable("$DIMDLI", [40], \.dimensionLineIncrement),
        Variable("$DIMLTYPE", [6], \.dimensionLineType),
        Variable("$DIMLWD", [70], \.dimensionLineWeight),
        Variable("$DIMTM", [40], \.dimensionMinusTolerance),
        Variable("$DIMMZF", [40], \.dimensionMzf),
        Variable("$DIMMZS", [6], \.dimensionMzs),
        Variable("$DIMTP", [40], \.dimensionPlusTolerance),
        Variable("$DIMPOST", [1], \.dimensionPostFix),
        Variable("$DIMRND", [40], \.dimensionRounding),
        Variable("$DIMSCALE", [40], \.dimensionScaleFactor),
        Variable("$DIMSAH", [70], \.dimensionSeparateArrowBlocks),
        Variable("$DIMSD1", [70], \.dimensionSuppressFirstDimensionLine),
        Variable("$DIMSE1", [70], \.dimensionSuppressFirstExtensionLine),
        Variable("$DIMSOXD", [70], \.dimensionSuppressOutsideExtensions),
        Variable("$DIMSD2", [70], \.dimensionSuppressSecondDimensionLine),
        Variable("$DIMSE2", [70], \.dimensionSuppressSecondExtensionLine),
        Variable("$DIMLTEX1", [6], \.dimensionTex1),
        Variable("$DIMLTEX2", [6], \.dimensionTex2),
        Variable("$DIMTFILLCLR", [62], ignored: true, \.dimensionTextBackgroundColor),
        Variable("$DIMTFILL", [70], \.dimensionTextBackgroundFillMode),
        Variable("$DIMCLRT", [70], \.dimensionTextColor),
        Variable("$DIMTXTDIRECTION", [70], \.dimensionTextDirection),
        Variable("$DIMTXT", [40], \.dimensionTextHeight),
        Variable("$DIMJUST", [70], \.dimensionTextHorizontalAlignment),
        Variable("$DIMTIX", [70], \.dimensionTextInsideExtensions),
        Variable("$DIMTIH", [70], \.dimensionTextInsideHorizontal),
        Variable("$DIMTMOVE", [70], \.dimensionTextMovement),
        Variable("$DIMTOFL", [70], \.dimensionTextOutsideExtensions),
        Variable("$DIMTOH", [70], \.dimensionTextOutsideHorizontal),
        Variable("$DIMTXSTY", [7], isName: true, \.dimensionTextStyleName),
        Variable("$DIMTAD", [70], \.dimensionTextVerticalAlignment),
        Variable("$DIMTVP", [40], \.dimensionTextVerticalPosition),
        Variable("$DIMTSZ", [40], \.dimensionTickSize),
        Variable("$DIMTOLJ", [70], \.dimensionToleranceAlignment),
        Variable("$DIMTDEC", [70], \.dimensionToleranceDecimalPlaces),
        Variable("$DIMTFAC", [40], \.dimensionToleranceScaleFactor),
        Variable("$DIMTZIN", [70], \.dimensionToleranceZeroHandling),
        Variable("$DIMUNIT", [70], \.dimensionUnit),
        Variable("$DIMZIN", [70], \.dimensionZeroHandling),
        Variable("$LIGHTGLYPHDISPLAY", [280], \.displayLightGlyphs),
        Variable("$LWDISPLAY", [290], \.displayLineWeight),
        Variable("$DISPSILH", [70], \.displaySilhouetteCurves),
        Variable("$LOFTANG1", [40], \.draftAngleFirstCrossSection),
        Variable("$LOFTANG2", [40], \.draftAngleSecondCrossSection),
        Variable("$LOFTMAG1", [40], \.draftMagnitudeFirstCrossSection),
        Variable("$LOFTMAG2", [40], \.draftMagnitudeSecondCrossSection),
        Variable("$3DDWFPREC", [40], \.dw3DPrecision),
        Variable("$DWFFRAME", [280], \.dwgUnderlayFramesVisibility),
        Variable("$ELEVATION", [40], \.elevation),
        Variable("$ENDCAPS", [280], \.endCaps),
        Variable("$SORTENTS", [280], \.entitySortingFlags),
        Variable("$EXTNAMES", [290], \.extendedNames),
        Variable("$DIMLWE", [70], \.extensionLineWeight),
        Variable("$XCLIPFRAME", [280], \.externalReferenceClippingBoundaryType),
        Variable("$FACETRES", [40], range: 0.01...10, \.facetResolution),
        Variable("$FILLETRAD", [40], \.filletRadius),
        Variable("$FILLMODE", [70], \.fillMode),
        Variable("$FINGERPRINTGUID", [2], \.fingerPrintGuid),
        Variable("$HALOGAP", [280], \.haloGapPercentage),
        Variable("$HANDSEED", [5], \.handleSeed),
        Variable("$HIDETEXT", [280], \.hideText),
        Variable("$HYPERLINKBASE", [1], \.hyperLinkBase),
        Variable("$INDEXCTL", [280], \.indexCreationFlags),
        Variable("$INSUNITS", [70], \.insUnits),
        Variable("$INTERFERECOLOR", [62], \.interfereColor),
        Variable("$JOINSTYLE", [280], \.joinStyle),
        Variable("$LASTSAVEDBY", [3], ignored: true, \.lastSavedBy),
        Variable("$LATITUDE", [40], \.latitude),
        Variable("$LENSLENGTH", [40], \.lensLength),
        Variable("$LIMCHECK", [70], \.limitCheckingOn),
        Variable("$LUNITS", [70], \.linearUnitFormat),
        Variable("$LUPREC", [70], range: 0...8, \.linearUnitPrecision),
        Variable("$LTSCALE", [40], \.lineTypeScale),
        Variable("$LOFTNORMALS", [280], \.loftedObjectNormals),
        Variable("$LONGITUDE", [40], \.longitude),
        Variable("$ACADMAINTVER", [70], ignored: true, \.maintenanceVersion),
        Variable("$MAXACTVP", [70], \.maxViewportCount),
        Variable("$MEASUREMENT", [70], \.measurementUnits),
        Variable("$MENU", [1], \.menuFileName),
        Variable("$MIRRTEXT", [70], \.mirrorText),
        Variable("$EXTMAX", [10, 20, 30], \.modelSpaceExtMax),
        Variable("$EXTMIN", [10, 20, 30], \.modelSpaceExtMin),
        Variable("$INSBASE", [10, 20, 30], \.modelSpaceInsertionBase),
        Variable("$LIMMAX", [10, 20], \.modelSpaceLimitsMax),
        Variable("$LIMMIN", [10, 20], \.modelSpaceLimitsMin),
        Variable("$UCSORG", [10, 20, 30], \.modelSpaceOrigin),
        Variable("$UCSORGBACK", [10, 20, 30], \.modelSpaceOrthographicBackDOrigin),
        Variable("$UCSORGBOTTOM", [10, 20, 30], \.modelSpaceOrthographicBottomDOrigin),
        Variable("$UCSORGFRONT", [10, 20, 30], \.modelSpaceOrthographicFrontDOrigin),
        Variable("$UCSORGLEFT", [10, 20, 30], \.modelSpaceOrthographicLeftDOrigin),
        Variable("$UCSORGRIGHT", [10, 20, 30], \.modelSpaceOrthographicRightDOrigin),
        Variable("$UCSORGTOP", [10, 20, 30], \.modelSpaceOrthographicTopDOrigin),
        Variable("$UCSXDIR", [10, 20, 30], \.modelSpaceXAxis),
        Variable("$UCSYDIR", [10, 20, 30], \.modelSpaceYAxis),
        Variable("$NORTHDIRECTION", [40], \.northDirection),
        Variable("$SPLINESEGS", [70], \.numberOfSplineSegments),
        Variable("$OSMODE", [70], \.objectSnapMode),
        Variable("$ORTHOMODE", [70], \.orthoMode),
        Variable("$PUCSBASE", [2], isName: true, \.paperSpaceBaseName),
        Variable("$PELEVATION", [40], \.paperSpaceElevation),
        Variable("$PEXTMAX", [10, 20, 30], \.paperSpaceExtMax),
        Variable("$PEXTMIN", [10, 20, 30], \.paperSpaceExtMin),
        Variable("$PINSBASE", [10, 20, 30], \.paperSpaceInsertionBase),
        Variable("$PLIMCHECK", [70], \.paperSpaceLimitsChecking),
        Variable("$PLIMMAX", [10, 20], \.paperSpaceLimitsMax),
        Variable("$PLIMMIN", [10, 20], \.paperSpaceLimitsMin),
        Variable("$PSLTSCALE", [70], \.paperSpaceLineTypeScaling),
        Variable("$PUCSNAME", [2], isName: true, \.paperSpaceName),
        Variable("$PUCSORGBACK", [10, 20, 30], \.paperSpaceOrthographicBackDOrigin),
        Variable("$PUCSORGBOTTOM", [10, 20, 30], \.paperSpaceOrthographicBottomDOrigin),
        Variable("$PUCSORGFRONT", [10, 20, 30], \.paperSpaceOrthographicFrontDOrigin),
        Variable("$PUCSORGLEFT", [10, 20, 30], \.paperSpaceOrthographicLeftDOrigin),
        Variable("$PUCSORGRIGHT", [10, 20, 30], \.paperSpaceOrthographicRightDOrigin),
        Variable("$PUCSORGTOP", [10, 20, 30], \.paperSpaceOrthographicTopDOrigin),
        Variable("$PUCSORG", [10, 20, 30], \.paperSpaceUcsOrigin),
        Variable("$PUCSXDIR", [10, 20, 30], \.paperSpaceUcsXAxis),
        Variable("$PUCSYDIR", [10, 20, 30], \.paperSpaceUcsYAxis),
        Variable("$PSTYLEMODE", [290], \.plotStyleMode),
        Variable("$PDMODE", [70], \.pointDisplayMode),
        Variable("$PDSIZE", [40], \.pointDisplaySize),
        Variable("$PLINEGEN", [70], \.polylineLineTypeGeneration),
        Variable("$PLINEWID", [40], \.polylineWidthDefault),
        Variable("$PROJECTNAME", [1], \.projectName),
        Variable("$PROXYGRAPHICS", [70], \.proxyGraphics),
        Variable("$QTEXTMODE", [70], \.quickTextMode),
        Variable("$REGENMODE", [70], \.regenerationMode),
        Variable("$REQUIREDVERSIONS", [70], ignored: true, \.requiredVersions),
        Variable("$VISRETAIN", [70], \.retainXRefDependentVisibilitySettings),
        Variable("$SHADEDIF", [70], \.shadeDiffuseToAmbientPercentage),
        Variable("$SHADEDGE", [70], \.shadeEdge),
        Variable("$CSHADOW", [280], \.shadowMode),
        Variable("$SHADOWPLANELOCATION", [40], \.shadowPlaneLocation),
        Variable("$TILEMODE", [70], \.showModelSpace),
        Variable("$SHOWHIST", [280], \.showSolidsHistory),
        Variable("$SPLFRAME", [70], \.showSplineControlPoints),
        Variable("$SKETCHINC", [40], \.sketchIncrement),
        Variable("$SKPOLY", [70], \.sketchPolylines),
        Variable("$LOFTPARAM", [70], \.solidLoftedShape),
        Variable("$SOLIDHIST", [280], \.solidsRetainHistory),
        Variable("$TREEDEPTH", [70], \.spatialIndexMaxTreeDepth),
        Variable("$SPLINETYPE", [70], \.splineType),
        Variable("$STEPSIZE", [40], \.stepSize),
        Variable("$STEPSPERSEC", [40], range: 1...30, \.stepsPerSecond),
        Variable("$STYLESHEET", [1], \.styleSheetName),
        Variable("$SURFU", [70], \.surfaceDensityU),
        Variable("$SURFV", [70], \.surfaceDensityV),
        Variable("$SURFTAB1", [70], \.surfaceMeshTabulationCount1),
        Variable("$SURFTAB2", [70], \.surfaceMeshTabulationCount2),
        Variable("$SURFTYPE", [70], \.surfaceType),
        Variable("$PSOLHEIGHT", [40], \.sweptSolidHeight),
        Variable("$PSOLWIDTH", [40], \.sweptSolidWidth),
        Variable("$TEXTSIZE", [40], \.textHeightDefault),
        Variable("$THICKNESS", [40], \.thicknessDefault),
        Variable("$TIMEZONE", [70], \.timeZone),
        Variable("$TDINDWG", [40], \.totalEditingTime),
        Variable("$TRACEWID", [40], \.traceWidthDefault),
        Variable("$UCSBASE", [2], isName: true, \.ucsBaseName),
        Variable("$UCSNAME", [2], isName: true, \.ucsName),
        Variable("$UNITMODE", [70], \.unitMode),
        Variable("$TDUCREATE", [40], \.universalCreateDateTime),
        Variable("$TDUUPDATE", [40], \.universalUpdateDateTime),
        Variable("$TDUPDATE", [40], \.updateDateTime),
        Variable("$DIMSHO", [70], \.updateDimensionsWhileDragging),
        Variable("$USERR1", [40], \.userDouble1),
        Variable("$USERR2", [40], \.userDouble2),
        Variable("$USERR3", [40], \.userDouble3),
        Variable("$USERR4", [40], \.userDouble4),
        Variable("$USERR5", [40], \.userDouble5),
        Variable("$TDUSRTIMER", [40], \.userElapsedTimeSpan),
        Variable("$USERI1", [70], \.userShort1),
        Variable("$USERI2", [70], \.userShort2),
        Variable("$USERI3", [70], \.userShort3),
        Variable("$USERI4", [70], \.userShort4),
        Variable("$USERI5", [70], \.userShort5),
        Variable("$USRTIMER", [70], \.userTimer),
        Variable("$VERSIONGUID", [2], \.versionGuid),
        Variable("$ACADVER", [1], \.versionString),
        Variable("$PSVPSCALE", [40], \.viewportDefaultViewScaleFactor),
        Variable("$WORLDVIEW", [70], \.worldView),
        Variable("$XEDIT", [290], \.xEdit),
        ]
    }
}
