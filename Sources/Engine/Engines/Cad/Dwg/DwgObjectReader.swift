// ACadSharp 3.8.0 `DwgObjectReader`: placeholder until the object reader port lands.

import Foundation

extension ACad {
    final class DwgObjectReader {
        init(_ version: Version, _ builder: DwgDocumentBuilder, _ reader: DwgStreamReader, _ handles: [UInt64],
             _ handleMap: [UInt64: Int64], _ classes: DxfClassCollection) throws {}

        func read() throws { throw DwgError.notImplemented }
    }
}
