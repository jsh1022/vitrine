import Foundation
import UIKit

// Read exact Spotify track URIs from a row's stored model. Never match by title or
// list position: an unresolved or ambiguous row has no badge.
@objc(SGRPopularityIdentity)
final class SGRPopularityIdentity: NSObject {
    @objc(trackURIFromObject:) static func trackURI(fromObject object: AnyObject) -> String? {
        var visited = Set<ObjectIdentifier>()
        var found = Set<String>()
        var remaining = 512
        func visit(_ value: Any, depth: Int) {
            guard depth <= 6, remaining > 0, found.count < 2 else { return }
            remaining -= 1
            if let text = value as? String {
                if text.range(of: "^spotify:track:[A-Za-z0-9]{22}$", options: .regularExpression) != nil { found.insert(text) }
                return
            }
            if let url = value as? URL { visit(url.absoluteString, depth: depth + 1); return }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class {
                let identifier = ObjectIdentifier(value as AnyObject)
                guard visited.insert(identifier).inserted else { return }
            }
            guard mirror.displayStyle == .class || mirror.displayStyle == .struct ||
                mirror.displayStyle == .optional || mirror.displayStyle == .tuple ||
                mirror.displayStyle == .dictionary else { return }
            for child in mirror.children { visit(child.value, depth: depth + 1) }
        }
        if let root = object as? UIView {
            var views = [root]
            var count = 0
            while let view = views.popLast(), count < 80, remaining > 0 {
                count += 1
                // Swift content views carry the row model, whereas UIKit base
                // classes don't expose their stored subviews through Mirror.
                visit(view, depth: 0)
                views.append(contentsOf: view.subviews)
            }
        } else {
            visit(object, depth: 0)
        }
        return found.count == 1 ? found.first : nil
    }
}
