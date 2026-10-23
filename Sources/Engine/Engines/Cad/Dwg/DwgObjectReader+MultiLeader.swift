// ACadSharp 3.8.0 DwgObjectReader: multileaders, their annotation context data (embedded in the MULTILEADER entity
// or stored as an ACDB_MLEADEROBJECTCONTEXTDATA_CLASS object) and multileader styles.

import Foundation

fileprivate typealias A = ACad

extension ACad {
    /// `CadMLeaderAnnotContextTemplate`: the handles of a multileader's annotation context.
    final class CadMLeaderAnnotContextTemplate: CadTemplate {
        var scaleHandle: UInt64?
        var blockRecordHandle: UInt64 = 0
        var textStyleHandle: UInt64 = 0
        var leaderLineTemplates: [CadMLeaderTemplate.LeaderLineTemplate] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let context = cadObject as! MultiLeaderObjectContextData
            if let scale: Scale = builder.tryGetObject(scaleHandle) { context.scale = scale }
            if let style: TextStyle = builder.tryGetObject(textStyleHandle) { context.textStyle = style }
            if let block: BlockRecord = builder.tryGetObject(blockRecordHandle) { context.blockContent = block }
            for template in leaderLineTemplates { template.build(builder) }
        }
    }
}

extension ACad.DwgObjectReader {
    func readMultiLeader() throws -> ACad.CadTemplate? {
        let mLeader = A.MultiLeader()
        let template = A.CadMLeaderTemplate(mLeader)

        try readCommonEntityData(template)

        if r2010Plus {
            // 270 Version, expected to be 2
            _ = try objectReader.readBitShort()
        }

        let context = A.CadMLeaderAnnotContextTemplate(mLeader.contextData)
        try readMultiLeaderAnnotContext(mLeader.contextData, context)
        template.contextTextStyleHandle = context.textStyleHandle
        template.contextBlockRecordHandle = context.blockRecordHandle
        template.leaderLineTemplates = context.leaderLineTemplates

        // 340 Leader StyleId (handle)
        template.leaderStyleHandle = try handleReference()
        // BL 90 Property Override Flags (int32)
        mLeader.propertyOverrideFlags = try objectReader.readBitLong()
        // BS 170 LeaderLineType (short)
        mLeader.pathType = try objectReader.readBitShort()
        // CMC 91 Leade LineColor (Color)
        mLeader.lineColor = try mergedReaders.readCmColor(useTextStream: false)
        // H 341 LeaderLineTypeID (handle/LineType)
        template.leaderLineTypeHandle = try handleReference()
        // BL 171 LeaderLine Weight
        mLeader.leaderLineWeight = A.LineWeight(Int16(truncatingIfNeeded: try objectReader.readBitLong()))
        // B 290 Enable Landing
        mLeader.enableLanding = try objectReader.readBit()
        // B 291 Enable Dogleg
        mLeader.enableDogleg = try objectReader.readBit()
        // 41 Dogleg Length / Landing distance
        mLeader.landingDistance = try objectReader.readBitDouble()
        // 342 Arrowhead ID
        template.arrowheadHandle = try handleReference()
        // 42 Arrowhead Size
        mLeader.arrowheadSize = try objectReader.readBitDouble()
        // BS 172 Content Type
        mLeader.contentType = try objectReader.readBitShort()
        // H 343 Text Style ID (handle/TextStyle)
        template.mtextStyleHandle = try handleReference()
        // 173 Text Left Attachment Type
        mLeader.textLeftAttachment = try objectReader.readBitShort()
        // 95 Text Right Attachment Type
        mLeader.textRightAttachment = try objectReader.readBitShort()
        // 174 Text Angle Type
        mLeader.textAngle = try objectReader.readBitShort()
        // 175 Text Alignment Type
        mLeader.textAlignment = try objectReader.readBitShort()
        // 92 Text Color
        mLeader.textColor = try mergedReaders.readCmColor(useTextStream: false)
        // 292 Enable Frame Text
        mLeader.textFrame = try objectReader.readBit()
        // 344 Block Content ID
        template.blockContentHandle = try handleReference()
        // 93 Block Content Color
        mLeader.blockContentColor = try mergedReaders.readCmColor(useTextStream: false)
        // 10 Block Content Scale
        mLeader.blockContentScale = try objectReader.read3BitDouble()
        // 43 Block Content Rotation
        mLeader.blockContentRotation = try objectReader.readBitDouble()
        // 176 Block Content Connection Type
        mLeader.blockContentConnection = try objectReader.readBitShort()
        // 293 Enable Annotation Scale/Is annotative
        mLeader.enableAnnotationScale = try objectReader.readBit()

        if r2007Pre {
            // BL number of arrow heads
            let arrowHeadCount = try objectReader.readBitLong()
            var index: Int32 = 0
            while index < arrowHeadCount {
                // ODA: 94 B Is Default
                let isDefault = try objectReader.readBit()
                // 345 Arrowhead ID (`Dictionary.Add`: a repeated handle fails the object)
                let handle = try handleReference()
                if template.arrowheadHandles.contains(where: { $0.0 == handle }) { throw A.DwgError.duplicateKey(handle) }
                template.arrowheadHandles.append((handle, isDefault))
                index += 1
            }
        }

        // BL Number of Block Labels
        let blockLabelCount = try objectReader.readBitLong()
        var label: Int32 = 0
        while label < blockLabelCount {
            // 330 Block Attribute definition handle (hard pointer)
            let attributeHandle = try handleReference()
            var blockAttribute = A.MultiLeader.BlockAttribute()
            // 302 Block Attribute Text String
            blockAttribute.text = try textReader.readVariableText()
            // 177 Block Attribute Index
            blockAttribute.index = try objectReader.readBitShort()
            // 44 Block Attribute Width
            blockAttribute.width = try objectReader.readBitDouble()
            mLeader.blockAttributes.append(blockAttribute)
            template.blockAttributeHandles.append(attributeHandle)
            label += 1
        }

        // 294 Text Direction Negative
        mLeader.textDirectionNegative = try objectReader.readBit()
        // 178 Text Align in IPE
        mLeader.textAligninIPE = try objectReader.readBitShort()
        // 179 Text Attachment Point
        mLeader.textAttachmentPoint = try objectReader.readBitShort()
        // 45 BD ScaleFactor
        mLeader.scaleFactor = try objectReader.readBitDouble()

        if r2010Plus {
            // 271 Text attachment direction for MText contents
            mLeader.textAttachmentDirection = try objectReader.readBitShort()
            // 272 Bottom text attachment direction (sequence my be interchanged)
            mLeader.textBottomAttachment = try objectReader.readBitShort()
            // 273 Top text attachment direction
            mLeader.textTopAttachment = try objectReader.readBitShort()
        }

        if r2013Plus {
            // 295 Leader extended to text
            mLeader.extendedToText = try objectReader.readBit()
        }

        return template
    }

    func readMultiLeaderAnnotContext() throws -> ACad.CadTemplate? {
        let annotContext = A.MultiLeaderObjectContextData()
        let template = A.CadMLeaderAnnotContextTemplate(annotContext)

        // readAnnotScaleObjectContextData
        try readObjectContextData(template)
        template.scaleHandle = try handleReference()

        try readMultiLeaderAnnotContext(annotContext, template)
        return template
    }

    @discardableResult
    func readMultiLeaderAnnotContext(_ annotContext: ACad.MultiLeaderObjectContextData,
                                     _ template: ACad.CadMLeaderAnnotContextTemplate) throws -> ACad.MultiLeaderObjectContextData {
        // BL - Number of leader roots
        var leaderRootCount = try objectReader.readBitLong()
        if leaderRootCount == 0 {
            var bits: [Bool] = []
            for _ in 0..<7 { bits.append(try objectReader.readBit()) }
            leaderRootCount = bits[5] ? 2 : 1
        }

        var i: Int32 = 0
        while i < leaderRootCount {
            annotContext.leaderRoots.append(try readLeaderRoot(template))
            i += 1
        }

        // Common
        // BD 40 Overall scale
        annotContext.scaleFactor = try objectReader.readBitDouble()
        // 3BD 10 Content base point
        annotContext.contentBasePoint = try objectReader.read3BitDouble()
        // BD 41 Text height
        annotContext.textHeight = try objectReader.readBitDouble()
        // BD 140 Arrow head size
        annotContext.arrowheadSize = try objectReader.readBitDouble()
        // BD 145 Landing gap
        annotContext.landingGap = try objectReader.readBitDouble()
        // BS 174 Style left text attachment type
        annotContext.textLeftAttachment = try objectReader.readBitShort()
        // BS 175 Style right text attachment type
        annotContext.textRightAttachment = try objectReader.readBitShort()
        // BS 176 Text align type (0 = left, 1 = center, 2 = right)
        annotContext.textAlignment = try objectReader.readBitShort()
        // BS 177 Attachment type (0 = content extents, 1 = insertion point).
        annotContext.blockContentConnection = try objectReader.readBitShort()
        // B 290 Has text contents
        annotContext.hasTextContents = try objectReader.readBit()
        if annotContext.hasTextContents {
            // TV 304 Text label
            annotContext.textLabel = try textReader.readVariableText()
            // 3BD 11 Normal vector
            annotContext.textNormal = try objectReader.read3BitDouble()
            // H 340 Text style handle (hard pointer)
            template.textStyleHandle = try handleReference()
            // 3BD 12 Location
            annotContext.textLocation = try objectReader.read3BitDouble()
            // 3BD 13 Direction
            annotContext.direction = try objectReader.read3BitDouble()
            // BD 42 Rotation (radians)
            annotContext.textRotation = try objectReader.readBitDouble()
            // BD 43 Boundary width
            annotContext.boundaryWidth = try objectReader.readBitDouble()
            // BD 44 Boundary height
            annotContext.boundaryHeight = try objectReader.readBitDouble()
            // BD 45 Line spacing factor
            annotContext.lineSpacingFactor = try objectReader.readBitDouble()
            // BS 170 Line spacing style (1 = at least, 2 = exactly)
            annotContext.lineSpacing = try objectReader.readBitShort()
            // CMC 90 Text color
            annotContext.textColor = try objectReader.readCmColor(useTextStream: false)
            // BS 171 Alignment (1 = left, 2 = center, 3 = right)
            annotContext.textAttachmentPoint = try objectReader.readBitShort()
            // BS 172 Flow direction (1 = horizontal, 3 = vertical, 6 = by style)
            annotContext.flowDirection = try objectReader.readBitShort()
            // CMC 91 Background fill color
            annotContext.backgroundFillColor = try objectReader.readCmColor(useTextStream: false)
            // BD 141 Background scale factor
            annotContext.backgroundScaleFactor = try objectReader.readBitDouble()
            // BL 92 Background transparency
            annotContext.backgroundTransparency = try objectReader.readBitLong()
            // B 291 Is background fill enabled
            annotContext.backgroundFillEnabled = try objectReader.readBit()
            // B 292 Is background mask fill on
            annotContext.backgroundMaskFillOn = try objectReader.readBit()
            // BS 173 Column type (ODA writes 0)
            annotContext.columnType = try objectReader.readBitShort()
            // B 293 Is text height automatic?
            annotContext.textHeightAutomatic = try objectReader.readBit()
            // BD 142 Column width
            annotContext.columnWidth = try objectReader.readBitDouble()
            // BD 143 Column gutter
            annotContext.columnGutter = try objectReader.readBitDouble()
            // B 294 Column flow reversed
            annotContext.columnFlowReversed = try objectReader.readBit()
            // BD 144 Column sizes
            let columnSizesCount = try objectReader.readBitLong()
            var c: Int32 = 0
            while c < columnSizesCount {
                annotContext.columnSizes.append(try objectReader.readBitDouble())
                c += 1
            }
            // B 295 Word break
            annotContext.wordBreak = try objectReader.readBit()
            // B Unknown
            _ = try objectReader.readBit()
        } else {
            // B 296 Has contents block
            annotContext.hasContentsBlock = try objectReader.readBit()
            if annotContext.hasContentsBlock {
                // H 341 AcDbBlockTableRecord handle (soft pointer)
                template.blockRecordHandle = try handleReference()
                // 3BD 14 Normal vector
                annotContext.blockContentNormal = try objectReader.read3BitDouble()
                // 3BD 15 Location
                annotContext.blockContentLocation = try objectReader.read3BitDouble()
                // 3BD 16 Scale vector
                annotContext.blockContentScale = try objectReader.read3BitDouble()
                // BD 46 Rotation (radians)
                annotContext.blockContentRotation = try objectReader.readBitDouble()
                // CMC 93 Block color
                annotContext.blockContentColor = try objectReader.readCmColor(useTextStream: false)
                // BD (16) 47 the complete transformation matrix (M00, M10, M20, M30, M01 …)
                var matrix: [Double] = []
                for _ in 0..<16 { matrix.append(try objectReader.readBitDouble()) }
                annotContext.transformationMatrix = matrix
            }
        }

        // 3BD 110 Base point
        annotContext.basePoint = try objectReader.read3BitDouble()
        // 3BD 111 Base direction
        annotContext.baseDirection = try objectReader.read3BitDouble()
        // 3BD 112 Base vertical
        annotContext.baseVertical = try objectReader.read3BitDouble()
        // B 297 Is normal reversed?
        annotContext.normalReversed = try objectReader.readBit()

        if r2010Plus {
            // BS 273 Style top attachment
            annotContext.textTopAttachment = try objectReader.readBitShort()
            // BS 272 Style bottom attachment
            annotContext.textBottomAttachment = try objectReader.readBitShort()
        }

        return annotContext
    }

    private func readLeaderRoot(_ template: ACad.CadMLeaderAnnotContextTemplate) throws -> ACad.MultiLeaderObjectContextData.LeaderRoot {
        let leaderRoot = A.MultiLeaderObjectContextData.LeaderRoot()

        // B 290 Is content valid(ODA writes true)/DXF: Has Set Last Leader Line Point
        leaderRoot.contentValid = try objectReader.readBit()
        // B 291 Unknown(ODA writes true)/DXF: Has Set Dogleg Vector
        leaderRoot.unknown = try objectReader.readBit()
        // 3BD 10 Connection point/DXF: Last Leader Line Point
        leaderRoot.connectionPoint = try objectReader.read3BitDouble()
        // 3BD 11 Direction/DXF: Dogleg vector
        leaderRoot.direction = try objectReader.read3BitDouble()

        // BL Number of break start / end point pairs; 3BD 12 Break start point, 3BD 13 Break end point
        let breakStartEndPointCount = try objectReader.readBitLong()
        var b: Int32 = 0
        while b < breakStartEndPointCount {
            leaderRoot.breakStartEndPointsPairs.append(.init(startPoint: try objectReader.read3BitDouble(),
                                                             endPoint: try objectReader.read3BitDouble()))
            b += 1
        }

        // BL 90 Leader index
        leaderRoot.leaderIndex = try objectReader.readBitLong()
        // BD 40 Landing distance
        leaderRoot.landingDistance = try objectReader.readBitDouble()

        // BL Number of leader lines
        let leaderLineCount = try objectReader.readBitLong()
        var l: Int32 = 0
        while l < leaderLineCount {
            leaderRoot.lines.append(try readLeaderLine(template))
            l += 1
        }

        if r2010Plus {
            // BS 271 Attachment direction(0 = horizontal, 1 = vertical, default is 0)
            leaderRoot.textAttachmentDirection = try objectReader.readBitShort()
        }

        return leaderRoot
    }

    private func readLeaderLine(_ template: ACad.CadMLeaderAnnotContextTemplate) throws -> ACad.MultiLeaderObjectContextData.LeaderLine {
        let leaderLine = A.MultiLeaderObjectContextData.LeaderLine()
        let lineTemplate = A.CadMLeaderTemplate.LeaderLineTemplate(leaderLine)
        template.leaderLineTemplates.append(lineTemplate)

        // BL - Number of points; 3BD 10 Point
        let pointCount = try objectReader.readBitLong()
        var p: Int32 = 0
        while p < pointCount {
            leaderLine.points.append(try objectReader.read3BitDouble())
            p += 1
        }

        // BL Break info count
        leaderLine.breakInfoCount = try objectReader.readBitLong()
        if leaderLine.breakInfoCount > 0 {
            // BL 90 Segment index
            leaderLine.segmentIndex = try objectReader.readBitLong()
            // Start/end point pairs: 3BD 11 Start Point, 3BD 12 End point
            let startEndPointCount = try objectReader.readBitLong()
            var s: Int32 = 0
            while s < startEndPointCount {
                leaderLine.startEndPoints.append(.init(startPoint: try objectReader.read3BitDouble(),
                                                       endPoint: try objectReader.read3BitDouble()))
                s += 1
            }
        }

        // BL 91 Leader line index
        leaderLine.index = try objectReader.readBitLong()

        if r2010Plus {
            // BS 170 Leader type(0 = invisible leader, 1 = straight leader, 2 = spline leader)
            leaderLine.pathType = try objectReader.readBitShort()
            // CMC 92 Line color
            leaderLine.lineColor = try objectReader.readCmColor(useTextStream: false)
            // H 340 Line type handle(hard pointer)
            lineTemplate.lineTypeHandle = try handleReference()
            // BL 171 Line weight
            leaderLine.lineWeight = A.LineWeight(Int16(truncatingIfNeeded: try objectReader.readBitLong()))
            // BD 40 Arrow size
            leaderLine.arrowheadSize = try objectReader.readBitDouble()
            // H 341 Arrow symbol handle(hard pointer)
            lineTemplate.arrowSymbolHandle = try handleReference()
            // BL 93 Override flags
            leaderLine.overrideFlags = try objectReader.readBitLong()
        }

        return leaderLine
    }

    func readMultiLeaderStyle() throws -> ACad.CadTemplate? {
        let mLeaderStyle = A.MultiLeaderStyle()
        let template = A.CadMLeaderStyleTemplate(mLeaderStyle)

        try readCommonNonEntityData(template)

        if r2010Plus {
            // BS 179 Version expected: 2
            _ = try objectReader.readBitShort()
        }

        // BS 170 Content type
        mLeaderStyle.contentType = try objectReader.readBitShort()
        // BS 171 Draw multi-leader order (0 = draw content first, 1 = draw leader first)
        mLeaderStyle.multiLeaderDrawOrder = try objectReader.readBitShort()
        // BS 172 Draw leader order (0 = draw leader head first, 1 = draw leader tail first)
        mLeaderStyle.leaderDrawOrder = try objectReader.readBitShort()
        // BL 90 Maximum number of points for leader
        mLeaderStyle.maxLeaderSegmentsPoints = try objectReader.readBitLong()
        // BD 40 First segment angle (radians)
        mLeaderStyle.firstSegmentAngleConstraint = try objectReader.readBitDouble()
        // BD 41 Second segment angle (radians)
        mLeaderStyle.secondSegmentAngleConstraint = try objectReader.readBitDouble()
        // BS 173 Leader type
        mLeaderStyle.pathType = try objectReader.readBitShort()
        // CMC 91 Leader line color
        mLeaderStyle.lineColor = try mergedReaders.readCmColor(useTextStream: false)
        // H 340 Leader line type handle (hard pointer)
        template.leaderLineTypeHandle = try handleReference()
        // BL 92 Leader line weight
        mLeaderStyle.leaderLineWeight = A.LineWeight(Int16(truncatingIfNeeded: try objectReader.readBitLong()))
        // B 290 Is landing enabled?
        mLeaderStyle.enableLanding = try objectReader.readBit()
        // BD 42 Landing gap
        mLeaderStyle.landingGap = try objectReader.readBitDouble()
        // B 291 Auto include landing (is dog-leg enabled?)
        mLeaderStyle.enableDogleg = try objectReader.readBit()
        // BD 43 Landing distance
        mLeaderStyle.landingDistance = try objectReader.readBitDouble()
        // TV 3 Style description
        mLeaderStyle.description = try mergedReaders.readVariableText()
        // H 341 Arrow head block handle (hard pointer)
        template.arrowheadHandle = try handleReference()
        // BD 44 Arrow head size
        mLeaderStyle.arrowheadSize = try objectReader.readBitDouble()
        // TV 300 Text default
        mLeaderStyle.defaultTextContents = try mergedReaders.readVariableText()
        // H 342 Text style handle (hard pointer)
        template.mtextStyleHandle = try handleReference()
        // BS 174 Left attachment
        mLeaderStyle.textLeftAttachment = try objectReader.readBitShort()
        // BS 178 Right attachment
        mLeaderStyle.textRightAttachment = try objectReader.readBitShort()
        // BS 175 Text angle type
        mLeaderStyle.textAngle = try objectReader.readBitShort()
        // BS 176 Text alignment type
        mLeaderStyle.textAlignment = try objectReader.readBitShort()
        // CMC 93 Text color
        mLeaderStyle.textColor = try mergedReaders.readCmColor(useTextStream: false)
        // BD 45 Text height
        mLeaderStyle.textHeight = try objectReader.readBitDouble()
        // B 292 Text frame enabled
        mLeaderStyle.textFrame = try objectReader.readBit()
        // B 297 Always align text left
        mLeaderStyle.textAlignAlwaysLeft = try objectReader.readBit()
        // BD 46 Align space
        mLeaderStyle.alignSpace = try objectReader.readBitDouble()
        // H 343 Block handle (hard pointer)
        template.blockContentHandle = try handleReference()
        // CMC 94 Block color
        mLeaderStyle.blockContentColor = try mergedReaders.readCmColor(useTextStream: false)
        // 3BD 47,49,140 Block scale vector
        mLeaderStyle.blockContentScale = try objectReader.read3BitDouble()
        // B 293 Is block scale enabled
        mLeaderStyle.enableBlockContentScale = try objectReader.readBit()
        // BD 141 Block rotation (radians)
        mLeaderStyle.blockContentRotation = try objectReader.readBitDouble()
        // B 294 Is block rotation enabled
        mLeaderStyle.enableBlockContentRotation = try objectReader.readBit()
        // BS 177 Block connection type
        mLeaderStyle.blockContentConnection = try objectReader.readBitShort()
        // BD 142 Scale factor
        mLeaderStyle.scaleFactor = try objectReader.readBitDouble()
        // B 295 Property changed
        mLeaderStyle.overwritePropertyValue = try objectReader.readBit()
        // B 296 Is annotative?
        mLeaderStyle.isAnnotative = try objectReader.readBit()
        // BD 143 Break size
        mLeaderStyle.breakGapSize = try objectReader.readBitDouble()

        if r2010Plus {
            // BS 271 Attachment direction
            mLeaderStyle.textAttachmentDirection = try objectReader.readBitShort()
            // BS 273 Top attachment (stored as the bottom one, like ACadSharp)
            mLeaderStyle.textBottomAttachment = try objectReader.readBitShort()
            // BS 272 Bottom attachment
            mLeaderStyle.textTopAttachment = try objectReader.readBitShort()
        }

        if r2013Plus {
            // B 298 Undocumented, found in DXF
            mLeaderStyle.unknownFlag298 = try objectReader.readBit()
        }

        return template
    }
}
