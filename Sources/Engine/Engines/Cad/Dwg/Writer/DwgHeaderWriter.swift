// ACadSharp 3.8.0 `DwgHeaderWriter`: the header variables section (AC1032 branches; the version flags are kept so
// the order of the fields reads like the reader's).

import Foundation

extension ACad {
    final class DwgHeaderWriter: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.header }
        private let output: DwgMemoryStream
        private let msmain = DwgMemoryStream()
        private let document: Document
        private let header: CadHeader

        init(_ output: DwgMemoryStream, _ document: Document) {
            self.output = output
            self.document = document
            header = document.header
            super.init(document.header.version)
        }

        /// `Table[name]` / `ObjectDictionaryCollection[name]`: a missing entry throws `KeyNotFoundException`.
        private func entry(_ object: CadObject?, _ name: String) throws -> UInt64 {
            guard let object else { throw DwgError.keyNotFound(name) }
            return object.handle
        }

        private func handle(_ object: CadObject?) -> UInt64 { object?.handle ?? 0 }

        func write() throws {
            let h = header
            let d = document
            // shortcut: the AC1032 path (merged writer, R2007+ layout); see DwgStreamWriter.swift.
            let w = DwgMergedStreamWriter(msmain)
            w.savePositionForSize()

            // R2013+: BLL : Variable REQUIREDVERSIONS, default value 0, read only.
            if r2013Plus { w.writeBitLongLong(0) }
            // Common: unknown values
            w.writeBitDouble(412_148_564_080.0)
            w.writeBitDouble(1.0)
            w.writeBitDouble(1.0)
            w.writeBitDouble(1.0)
            w.writeVariableText("m")
            w.writeVariableText("")
            w.writeVariableText("")
            w.writeVariableText("")
            w.writeBitLong(24)
            w.writeBitLong(0)

            w.writeBit(h.associatedDimensions)
            w.writeBit(h.updateDimensionsWhileDragging)
            w.writeBit(h.polylineLineTypeGeneration)
            w.writeBit(h.orthoMode)
            w.writeBit(h.regenerationMode)
            w.writeBit(h.fillMode)
            w.writeBit(h.quickTextMode)
            w.writeBit(h.paperSpaceLineTypeScaling == 1) // SpaceLineTypeScaling.Normal
            w.writeBit(h.limitCheckingOn)
            // R2004+: B : Undocumented
            w.writeBit(false)
            w.writeBit(h.userTimer)
            w.writeBit(h.sketchPolylines)
            w.writeBit(h.angularDirection != 0) // AngularDirection.CounterClockWise
            w.writeBit(h.showSplineControlPoints)
            w.writeBit(h.mirrorText)
            w.writeBit(h.worldView)
            w.writeBit(h.showModelSpace)
            w.writeBit(h.paperSpaceLimitsChecking)
            w.writeBit(h.retainXRefDependentVisibilitySettings)
            w.writeBit(h.displaySilhouetteCurves)
            w.writeBit(h.createEllipseAsPolyline)
            w.writeBitShort(h.proxyGraphics ? 1 : 0)
            w.writeBitShort(h.spatialIndexMaxTreeDepth)
            w.writeBitShort(h.linearUnitFormat)
            w.writeBitShort(h.linearUnitPrecision)
            w.writeBitShort(h.angularUnit)
            w.writeBitShort(h.angularUnitPrecision)
            w.writeBitShort(Int16(truncatingIfNeeded: h.attributeVisibility))
            w.writeBitShort(h.pointDisplayMode)
            // R2004+: 3 unknown BL
            w.writeBitLong(0)
            w.writeBitLong(0)
            w.writeBitLong(0)
            w.writeBitShort(h.userShort1)
            w.writeBitShort(h.userShort2)
            w.writeBitShort(h.userShort3)
            w.writeBitShort(h.userShort4)
            w.writeBitShort(h.userShort5)
            w.writeBitShort(h.numberOfSplineSegments)
            w.writeBitShort(h.surfaceDensityU)
            w.writeBitShort(h.surfaceDensityV)
            w.writeBitShort(h.surfaceType)
            w.writeBitShort(h.surfaceMeshTabulationCount1)
            w.writeBitShort(h.surfaceMeshTabulationCount2)
            w.writeBitShort(h.splineType)
            w.writeBitShort(h.shadeEdge)
            w.writeBitShort(h.shadeDiffuseToAmbientPercentage)
            w.writeBitShort(h.unitMode)
            w.writeBitShort(h.maxViewportCount)
            w.writeBitShort(h.surfaceIsolineCount)
            w.writeBitShort(h.currentMultiLineJustification)
            w.writeBitShort(h.textQuality)
            w.writeBitDouble(h.lineTypeScale)
            w.writeBitDouble(h.textHeightDefault)
            w.writeBitDouble(h.traceWidthDefault)
            w.writeBitDouble(h.sketchIncrement)
            w.writeBitDouble(h.filletRadius)
            w.writeBitDouble(h.thicknessDefault)
            w.writeBitDouble(h.angleBase)
            w.writeBitDouble(h.pointDisplaySize)
            w.writeBitDouble(h.polylineWidthDefault)
            w.writeBitDouble(h.userDouble1)
            w.writeBitDouble(h.userDouble2)
            w.writeBitDouble(h.userDouble3)
            w.writeBitDouble(h.userDouble4)
            w.writeBitDouble(h.userDouble5)
            w.writeBitDouble(h.chamferDistance1)
            w.writeBitDouble(h.chamferDistance2)
            w.writeBitDouble(h.chamferLength)
            w.writeBitDouble(h.chamferAngle)
            w.writeBitDouble(h.facetResolution)
            w.writeBitDouble(h.currentMultilineScale)
            w.writeBitDouble(h.currentEntityLinetypeScale)
            w.writeVariableText(h.menuFileName)
            w.writeDateTime(h.createDateTime)
            w.writeDateTime(h.updateDateTime)
            // R2004+: 3 unknown BL
            w.writeBitLong(0)
            w.writeBitLong(0)
            w.writeBitLong(0)
            w.writeTimeSpan(h.totalEditingTime)
            w.writeTimeSpan(h.userElapsedTimeSpan)
            w.writeCmColor(h.currentEntityColor)
            // HANDSEED goes to the data stream.
            w.main.handleReference(.undefined, h.handleSeed)
            w.handleReference(.hardPointer, try entry(d.layers[h.currentLayerName], h.currentLayerName))
            w.handleReference(.hardPointer, try entry(d.textStyles[h.currentTextStyleName], h.currentTextStyleName))
            w.handleReference(.hardPointer, try entry(d.lineTypes[h.currentLineTypeName], h.currentLineTypeName))
            // R2007+: CMATERIAL
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, try entry(d.dimensionStyles[h.currentDimensionStyleName], h.currentDimensionStyleName))
            guard let mlineStyles = d.mlineStyles else { throw DxfWriteError.nullReference }
            w.handleReference(.hardPointer, try entry(mlineStyles[h.currentMLineStyleName], h.currentMLineStyleName))
            w.writeBitDouble(h.viewportDefaultViewScaleFactor)
            w.write3BitDouble(h.paperSpaceInsertionBase)
            w.write3BitDouble(h.paperSpaceExtMin)
            w.write3BitDouble(h.paperSpaceExtMax)
            w.write2RawDouble(h.paperSpaceLimitsMin)
            w.write2RawDouble(h.paperSpaceLimitsMax)
            w.writeBitDouble(h.paperSpaceElevation)
            w.write3BitDouble(h.paperSpaceUcsOrigin)
            w.write3BitDouble(h.paperSpaceUcsXAxis)
            w.write3BitDouble(h.paperSpaceUcsYAxis)
            // UCSNAME (PSPACE): the header's own UCS object, never registered (handle 0).
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.writeBitShort(0)
            w.handleReference(.hardPointer, 0)
            w.write3BitDouble(h.paperSpaceOrthographicTopDOrigin)
            w.write3BitDouble(h.paperSpaceOrthographicBottomDOrigin)
            w.write3BitDouble(h.paperSpaceOrthographicLeftDOrigin)
            w.write3BitDouble(h.paperSpaceOrthographicRightDOrigin)
            w.write3BitDouble(h.paperSpaceOrthographicFrontDOrigin)
            w.write3BitDouble(h.paperSpaceOrthographicBackDOrigin)
            w.write3BitDouble(h.modelSpaceInsertionBase)
            w.write3BitDouble(h.modelSpaceExtMin)
            w.write3BitDouble(h.modelSpaceExtMax)
            w.write2RawDouble(h.modelSpaceLimitsMin)
            w.write2RawDouble(h.modelSpaceLimitsMax)
            w.writeBitDouble(h.elevation)
            w.write3BitDouble(h.modelSpaceOrigin)
            w.write3BitDouble(h.modelSpaceXAxis)
            w.write3BitDouble(h.modelSpaceYAxis)
            // UCSNAME (MSPACE): the header's own UCS object (handle 0).
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.writeBitShort(0)
            w.handleReference(.hardPointer, 0)
            w.write3BitDouble(h.modelSpaceOrthographicTopDOrigin)
            w.write3BitDouble(h.modelSpaceOrthographicBottomDOrigin)
            w.write3BitDouble(h.modelSpaceOrthographicLeftDOrigin)
            w.write3BitDouble(h.modelSpaceOrthographicRightDOrigin)
            w.write3BitDouble(h.modelSpaceOrthographicFrontDOrigin)
            w.write3BitDouble(h.modelSpaceOrthographicBackDOrigin)
            w.writeVariableText(h.dimensionPostFix)
            w.writeVariableText(h.dimensionAlternateDimensioningSuffix)

            w.writeBitDouble(h.dimensionScaleFactor)
            w.writeBitDouble(h.dimensionArrowSize)
            w.writeBitDouble(h.dimensionExtensionLineOffset)
            w.writeBitDouble(h.dimensionLineIncrement)
            w.writeBitDouble(h.dimensionExtensionLineExtension)
            w.writeBitDouble(h.dimensionRounding)
            w.writeBitDouble(h.dimensionLineExtension)
            w.writeBitDouble(h.dimensionPlusTolerance)
            w.writeBitDouble(h.dimensionMinusTolerance)
            // R2007+
            w.writeBitDouble(h.dimensionFixedExtensionLineLength)
            w.writeBitDouble(h.dimensionJoggedRadiusDimensionTransverseSegmentAngle)
            w.writeBitShort(h.dimensionTextBackgroundFillMode)
            w.writeCmColor(h.dimensionTextBackgroundColor)
            // R2000+
            w.writeBit(h.dimensionGenerateTolerances)
            w.writeBit(h.dimensionLimitsGeneration)
            w.writeBit(h.dimensionTextInsideHorizontal)
            w.writeBit(h.dimensionTextOutsideHorizontal)
            w.writeBit(h.dimensionSuppressFirstExtensionLine)
            w.writeBit(h.dimensionSuppressSecondExtensionLine)
            w.writeBitShort(Int16(truncatingIfNeeded: h.dimensionTextVerticalAlignment))
            w.writeBitShort(Int16(h.dimensionZeroHandling))
            w.writeBitShort(Int16(h.dimensionAngularZeroHandling))
            // R2007+
            w.writeBitShort(h.dimensionArcLengthSymbolPosition)
            w.writeBitDouble(h.dimensionTextHeight)
            w.writeBitDouble(h.dimensionCenterMarkSize)
            w.writeBitDouble(h.dimensionTickSize)
            w.writeBitDouble(h.dimensionAlternateUnitScaleFactor)
            w.writeBitDouble(h.dimensionLinearScaleFactor)
            w.writeBitDouble(h.dimensionTextVerticalPosition)
            w.writeBitDouble(h.dimensionToleranceScaleFactor)
            w.writeBitDouble(h.dimensionLineGap)
            // R2000+
            w.writeBitDouble(h.dimensionAlternateUnitRounding)
            w.writeBit(h.dimensionAlternateUnitDimensioning)
            w.writeBitShort(h.dimensionAlternateUnitDecimalPlaces)
            w.writeBit(h.dimensionTextOutsideExtensions)
            w.writeBit(h.dimensionSeparateArrowBlocks)
            w.writeBit(h.dimensionTextInsideExtensions)
            w.writeBit(h.dimensionSuppressOutsideExtensions)
            w.writeCmColor(h.dimensionLineColor)
            w.writeCmColor(h.dimensionExtensionLineColor)
            w.writeCmColor(h.dimensionTextColor)
            // R2000+
            w.writeBitShort(h.dimensionAngularDimensionDecimalPlaces)
            w.writeBitShort(h.dimensionDecimalPlaces)
            w.writeBitShort(h.dimensionToleranceDecimalPlaces)
            w.writeBitShort(h.dimensionAlternateUnitFormat)
            w.writeBitShort(h.dimensionAlternateUnitToleranceDecimalPlaces)
            w.writeBitShort(h.dimensionAngularUnit)
            w.writeBitShort(h.dimensionFractionFormat)
            w.writeBitShort(h.dimensionLinearUnitFormat)
            w.writeBitShort(Int16(bitPattern: h.dimensionDecimalSeparator))
            w.writeBitShort(h.dimensionTextMovement)
            w.writeBitShort(Int16(h.dimensionTextHorizontalAlignment))
            w.writeBit(h.dimensionSuppressFirstExtensionLine)
            w.writeBit(h.dimensionSuppressSecondExtensionLine)
            w.writeBitShort(Int16(h.dimensionToleranceAlignment))
            w.writeBitShort(Int16(h.dimensionToleranceZeroHandling))
            w.writeBitShort(Int16(h.dimensionAlternateUnitZeroHandling))
            w.writeBitShort(Int16(h.dimensionAlternateUnitToleranceZeroHandling))
            w.writeBit(h.dimensionCursorUpdate)
            w.writeBitShort(Int16(h.dimensionDimensionTextArrowFit))
            // R2007+
            w.writeBit(h.dimensionIsExtensionLineLengthFixed)
            // R2010+
            w.writeBit(h.dimensionTextDirection == 1) // TextDirection.RightToLeft
            w.writeBitDouble(h.dimensionAltMzf)
            w.writeVariableText(h.dimensionAltMzs)
            w.writeBitDouble(h.dimensionMzf)
            w.writeVariableText(h.dimensionMzs)
            // R2000+
            w.handleReference(.hardPointer, try entry(d.textStyles[h.dimensionTextStyleName], h.dimensionTextStyleName))
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            // R2007+
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            // R2000+
            w.writeBitShort(h.dimensionLineWeight.rawValue)
            w.writeBitShort(h.extensionLineWeight.rawValue)

            w.handleReference(.hardOwnership, d.blockRecords.handle)
            w.handleReference(.hardOwnership, d.layers.handle)
            w.handleReference(.hardOwnership, d.textStyles.handle)
            w.handleReference(.hardOwnership, d.lineTypes.handle)
            w.handleReference(.hardOwnership, d.views.handle)
            w.handleReference(.hardOwnership, d.ucss.handle)
            w.handleReference(.hardOwnership, d.vports.handle)
            w.handleReference(.hardOwnership, d.appIds.handle)
            w.handleReference(.hardOwnership, d.dimensionStyles.handle)
            w.handleReference(.hardPointer, handle(d.groups?.dictionary))
            w.handleReference(.hardPointer, handle(d.mlineStyles?.dictionary))
            w.handleReference(.hardOwnership, handle(d.rootDictionary))
            // R2000+
            w.writeBitShort(h.stackedTextAlignment)
            w.writeBitShort(h.stackedTextSizePercentage)
            w.writeVariableText(h.hyperLinkBase)
            w.writeVariableText(h.styleSheetName)
            w.handleReference(.hardPointer, handle(d.layouts?.dictionary))
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            // R2004+
            w.handleReference(.hardPointer, handle(d.materials?.dictionary))
            w.handleReference(.hardPointer, handle(d.colors?.dictionary))
            // R2007+, R2013+
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            // R2000+
            var flags = Int32(h.currentEntityLineWeight.rawValue) & 0x1F | Int32(h.endCaps) << 0x5 | Int32(h.joinStyle) << 0x7
            if !h.displayLineWeight { flags |= 0x200 }
            if !h.xEdit { flags |= 0x400 }
            if h.extendedNames { flags |= 0x800 }
            if h.plotStyleMode == 1 { flags |= 0x2000 }
            if h.loadOLEObject { flags |= 0x4000 }
            w.writeBitLong(flags)
            w.writeBitShort(h.insUnits)
            w.writeBitShort(h.currentEntityPlotStyle)
            if h.currentEntityPlotStyle == 3 { // EntityPlotStyleType.ByObjectId
                w.handleReference(.hardPointer, 0)
            }
            w.writeVariableText(h.fingerPrintGuid)
            w.writeVariableText(h.versionGuid)
            // R2004+
            w.writeByte(h.entitySortingFlags)
            w.writeByte(h.indexCreationFlags)
            w.writeByte(h.hideText)
            w.writeByte(UInt8(truncatingIfNeeded: h.externalReferenceClippingBoundaryType))
            w.writeByte(UInt8(truncatingIfNeeded: h.dimensionAssociativity))
            w.writeByte(h.haloGapPercentage)
            w.writeBitShort(h.obscuredColor.index)
            w.writeBitShort(h.interfereColor.index)
            w.writeByte(h.obscuredType)
            w.writeByte(h.intersectionDisplay)
            w.writeVariableText(h.projectName)
            w.handleReference(.hardPointer, handle(d.paperSpace))
            w.handleReference(.hardPointer, d.modelSpace.handle)
            w.handleReference(.hardPointer, try entry(d.lineTypes["ByLayer"], "ByLayer"))
            w.handleReference(.hardPointer, try entry(d.lineTypes["ByBlock"], "ByBlock"))
            w.handleReference(.hardPointer, try entry(d.lineTypes["Continuous"], "Continuous"))
            // R2007+
            w.writeBit(h.cameraDisplayObjects)
            w.writeBitLong(0)
            w.writeBitLong(0)
            w.writeBitDouble(0)
            w.writeBitDouble(h.stepsPerSecond)
            w.writeBitDouble(h.stepSize)
            w.writeBitDouble(h.dw3DPrecision)
            w.writeBitDouble(h.lensLength)
            w.writeBitDouble(h.cameraHeight)
            w.writeByte(UInt8(truncatingIfNeeded: h.solidsRetainHistory))
            w.writeByte(UInt8(truncatingIfNeeded: h.showSolidsHistory))
            w.writeBitDouble(h.sweptSolidWidth)
            w.writeBitDouble(h.sweptSolidHeight)
            w.writeBitDouble(h.draftAngleFirstCrossSection)
            w.writeBitDouble(h.draftAngleSecondCrossSection)
            w.writeBitDouble(h.draftMagnitudeFirstCrossSection)
            w.writeBitDouble(h.draftMagnitudeSecondCrossSection)
            w.writeBitShort(h.solidLoftedShape)
            w.writeByte(UInt8(truncatingIfNeeded: h.loftedObjectNormals))
            w.writeBitDouble(h.latitude)
            w.writeBitDouble(h.longitude)
            w.writeBitDouble(h.northDirection)
            w.writeBitLong(h.timeZone)
            w.writeByte(UInt8(truncatingIfNeeded: h.displayLightGlyphs))
            w.writeByte(UInt8(ascii: "0"))
            w.writeByte(UInt8(truncatingIfNeeded: h.dwgUnderlayFramesVisibility))
            w.writeByte(UInt8(truncatingIfNeeded: h.dgnUnderlayFramesVisibility))
            w.writeBit(false)
            w.writeCmColor(h.interfereColor)
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.handleReference(.hardPointer, 0)
            w.writeByte(h.shadowMode)
            w.writeBitDouble(h.shadowPlaneLocation)
            // R14+
            w.writeBitShort(-1)
            w.writeBitShort(-1)
            w.writeBitShort(-1)
            w.writeBitShort(-1)
            // R2004+
            w.writeBitLong(0)
            w.writeBitLong(0)
            w.writeBit(false)

            try w.writeSpearShift()
            writeSizeAndCrc()
        }

        private func writeSizeAndCrc() {
            output.write(DwgSectionDefinition.startSentinels[sectionName]!)
            var data: [UInt8] = DwgLE.bytes(Int32(truncatingIfNeeded: msmain.length))
            if r2010Plus && header.maintenanceVersion > 3 || r2018Plus {
                data += DwgLE.bytes(Int32(0))
            }
            data += msmain.bytes
            let crc = DwgCrc.crc8(0xC0C1, data)
            output.write(data)
            output.write(DwgLE.bytes(crc))
            output.write(DwgSectionDefinition.endSentinels[sectionName]!)
        }
    }
}
