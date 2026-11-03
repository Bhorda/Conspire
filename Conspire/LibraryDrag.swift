//
//  LibraryDrag.swift
//  Conspire
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What a library item carries while it is being dragged.
///
/// Encoded as plain text rather than a custom `UTType`. A custom type would
/// have to be declared in the Info.plist as an exported identifier, and
/// `UTType(exportedAs:)` traps at runtime when it is not — a brittle thing to
/// stake drag and drop on when a URL-ish string does the job.
struct LibraryDragPayload: Transferable, Equatable {
    enum Kind: String {
        case image
        case text
    }

    let kind: Kind
    let resourceID: UUID

    private static let scheme = "conspire-library"

    var encoded: String {
        "\(Self.scheme)://\(kind.rawValue)/\(resourceID.uuidString)"
    }

    init(kind: Kind, resourceID: UUID) {
        self.kind = kind
        self.resourceID = resourceID
    }

    init?(encoded: String) {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\(Self.scheme)://") else { return nil }
        let body = trimmed.dropFirst("\(Self.scheme)://".count)
        let parts = body.split(separator: "/")
        guard parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        self.kind = kind
        self.resourceID = id
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.encoded)
    }
}

/// Everything the canvas accepts on a drop: a file from Finder, or an item
/// dragged out of the library.
///
/// One `Transferable` with two importing representations, rather than two
/// `dropDestination` modifiers stacked on the same view — which would leave
/// which one wins up to SwiftUI.
enum CanvasDrop: Transferable {
    case file(URL)
    case libraryItem(LibraryDragPayload)

    enum DropError: Error {
        case notALibraryItem
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (drop: CanvasDrop) -> String in
            switch drop {
            case .file(let url): return url.absoluteString
            case .libraryItem(let payload): return payload.encoded
            }
        } importing: { text in
            guard let payload = LibraryDragPayload(encoded: text) else {
                throw DropError.notALibraryItem
            }
            return .libraryItem(payload)
        }

        ProxyRepresentation { (drop: CanvasDrop) -> URL in
            switch drop {
            case .file(let url): return url
            case .libraryItem(let payload): return URL(string: payload.encoded)!
            }
        } importing: { url in
            .file(url)
        }
    }
}
