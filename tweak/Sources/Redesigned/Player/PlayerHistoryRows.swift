// Spotify 9.1.90 runtime evidence: QueueCell and QueueViewController's factories share
// ConfigurableComponent<TrackRowQueue.Model, TrackRowQueue.Event, UIView>. Reuse that
// renderer instead of drawing a second kind of queue row. Swift ABI metadata supplies
// exact field types/offsets; an unrecognized shape leaves the original queue alone.
// All entry points run on main. No absolute executable addresses or copied native models.
import Foundation
import UIKit

private struct SGRQueueField {
    let name: String
    let offset: Int
    let type: Any.Type
}
private func sgrModelFields(_ type: Any.Type) -> [SGRQueueField]? {
    let m = unsafeBitCast(type, to: UnsafePointer<UInt>.self)
    guard m[0] == 0x200, let descriptor = UnsafeRawPointer(bitPattern: m[1]), let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_getTypeByMangledNameInContext") else { return nil }
    let n = Int(descriptor.load(fromByteOffset: 20, as: UInt32.self))
    let vector = Int(descriptor.load(fromByteOffset: 24, as: UInt32.self))
    let fieldRel = descriptor.advanced(by: 16)
    let fields = fieldRel.advanced(by: Int(fieldRel.load(as: Int32.self)))
    guard n < 50, fields.load(fromByteOffset: 10, as: UInt16.self) == 12, vector > 0 else { return nil }
    let resolve = unsafeBitCast(sym, to: (@convention(c) (UnsafePointer<CChar>, UInt, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?).self)
    var result: [SGRQueueField] = []
    for i in 0..<n {
        let r = fields.advanced(by: 16 + 12*i)
        let nr = r.advanced(by: 8), tr = r.advanced(by: 4)
        let name = String(cString: nr.advanced(by: Int(nr.load(as: Int32.self))).assumingMemoryBound(to: CChar.self))
        let t = tr.advanced(by: Int(tr.load(as: Int32.self)))
        var len = 0
        while len < 1024 {
            let b = t.load(fromByteOffset: len, as: UInt8.self)
            if b == 0 { break }
            len += (1...0x17).contains(b) ? 5 : ((0x18...0x1f).contains(b) ? 9 : 1)
        }
        guard let meta = resolve(t.assumingMemoryBound(to: CChar.self), UInt(len), descriptor, nil) else { return nil }
        let offset = UnsafeRawPointer(m.advanced(by: vector)).load(fromByteOffset: i*4, as: UInt32.self)
        result.append(SGRQueueField(name: name, offset: Int(offset), type: unsafeBitCast(meta, to: Any.Type.self)))
    }
    return result
}
@_silgen_name("SGRQueueUpdateCall") private func sgrInvokeUpdate(_ code: UnsafeRawPointer, _ context: UnsafeRawPointer?, _ model: UnsafeRawPointer, _ delta: UnsafeRawPointer)
private func sgrClassFields(_ type: Any.Type) -> [SGRQueueField] {
    guard let cls = type as? AnyClass,
          let descriptorSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_getTypeContextDescriptor"),
          let resolveSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_getTypeByMangledNameInContext") else { return [] }
    let getDescriptor = unsafeBitCast(descriptorSymbol, to: (@convention(c)(UnsafeRawPointer) -> UnsafeRawPointer?).self)
    guard let descriptor = getDescriptor(unsafeBitCast(type, to: UnsafeRawPointer.self)) else { return [] }
    let fr = descriptor.advanced(by: 16)
    let rel = fr.load(as: Int32.self)
    guard rel != 0 else { return [] }
    let f = fr.advanced(by: Int(rel))
    let n = Int(f.load(fromByteOffset: 12, as: UInt32.self))
    guard n < 150, f.load(fromByteOffset: 10, as: UInt16.self) == 12 else { return [] }
    let resolve = unsafeBitCast(resolveSymbol, to: (@convention(c)(UnsafePointer<CChar>, UInt, UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?).self)
    var result: [SGRQueueField] = []
    for i in 0..<n {
        let r = f.advanced(by: 16+12*i), nr = r.advanced(by: 8), tr = r.advanced(by: 4)
        let name = String(cString: nr.advanced(by: Int(nr.load(as: Int32.self))).assumingMemoryBound(to: CChar.self))
        guard let ivar = class_getInstanceVariable(cls, name) else { continue }
        let t = tr.advanced(by: Int(tr.load(as: Int32.self)))
        var len = 0
        while len < 1024 {
            let b = t.load(fromByteOffset: len, as: UInt8.self)
            if b == 0 { break }
            len += (1...0x17).contains(b) ? 5 : ((0x18...0x1f).contains(b) ? 9 : 1)
        }
        guard let m = resolve(t.assumingMemoryBound(to: CChar.self), UInt(len), descriptor, nil) else { continue }
        result.append(SGRQueueField(name: name, offset: ivar_getOffset(ivar), type: unsafeBitCast(m, to: Any.Type.self)))
    }
    return result
}
private func sgrEnumCase(_ type: Any.Type, name: String) -> Any? {
    let m = unsafeBitCast(type, to: UnsafePointer<UInt>.self)
    guard m[0] == 0x201, let d = UnsafeRawPointer(bitPattern: m[1]) else { return nil }
    let fr = d.advanced(by: 16), f = fr.advanced(by: Int(fr.load(as: Int32.self)))
    let n = Int(f.load(fromByteOffset: 12, as: UInt32.self))
    guard n < 16, f.load(fromByteOffset: 10, as: UInt16.self) == 12 else { return nil }
    var tag: UInt8?
    for i in 0..<n {
        let r = f.advanced(by: 16+12*i)
        guard r.load(fromByteOffset: 4, as: Int32.self) == 0 else { return nil }
        let nr = r.advanced(by: 8)
        if String(cString: nr.advanced(by: Int(nr.load(as: Int32.self))).assumingMemoryBound(to: CChar.self)) == name { tag = UInt8(i) }
    }
    guard let tag else { return nil }
    func create<E>(_ t: E.Type) -> Any? {
        guard MemoryLayout<E>.size == 1 else { return nil }
        let p = UnsafeMutablePointer<E>.allocate(capacity: 1)
        UnsafeMutableRawPointer(p).storeBytes(of: tag, as: UInt8.self)
        let value = p.move();p.deallocate()
        guard String(describing: value) == name else { return nil }
        return value
    }
    return _openExistential(type, do: create)
}
private func sgrEmptyArray(_ type: Any.Type) -> Any? {
    guard String(reflecting: type).hasPrefix("Swift.Array<") else { return nil }
    let m = unsafeBitCast(type, to: UnsafePointer<UInt>.self)
    let element = unsafeBitCast(m[2], to: Any.Type.self)
    func empty<E>(_ e: E.Type) -> Any { [E]() }
    return _openExistential(element, do: empty)
}
private func sgrUpdateRow(_ component: AnyObject, title: String, subtitle: String, cover: URL?) -> Bool {
    guard let update = Mirror(reflecting: component).children.first(where: { $0.label == "_update" })?.value else { return false }
    let m = unsafeBitCast(type(of: update), to: UnsafePointer<UInt>.self)
    guard m[0] == 0x302, m[1] == 0x4000002, let optionalModel = UnsafePointer<UInt>(bitPattern: m[3]) else { return false }
    let modelType = unsafeBitCast(optionalModel[2], to: Any.Type.self)
    guard String(reflecting: modelType).hasSuffix(".TrackRowQueue.Model"), let fields = sgrModelFields(modelType), Set(fields.map(\.name)) == Set(["name", "subtitle", "coverArt", "restriction", "isPlayable", "playState", "isSelectorVisible", "isReordering", "isSelected", "isRecommendation", "collaborators", "isMusicVideo", "willPlayAsVideo", "isVideoBadgeVisible", "isQueuedBadgeVisible", "isPlayButtonVisible", "animated", "isKallax"]) else { return false }
    var values: [String: Any] = [:]
    for f in fields {
        if f.type == String.self { values[f.name] = f.name == "name" ? title : subtitle }
        else if f.type == Bool.self { values[f.name] = f.name == "isPlayable" }
        else if f.type == Optional<URL>.self { values[f.name] = cover as Any }
        else if f.name == "collaborators" { values[f.name] = sgrEmptyArray(f.type) }
        else if f.name == "restriction" || f.name == "playState" { values[f.name] = sgrEnumCase(f.type, name: "none") }
        else { return false }
        guard values[f.name] != nil else { return false }
    }
    func withClosure<F>(_ t: F.Type) -> (UnsafeRawPointer, UnsafeRawPointer?)? {
        guard MemoryLayout<F>.size == 16, let typed = update as? F else { return nil }
        return withUnsafeBytes(of: typed) { bytes in (bytes.load(as: UnsafeRawPointer.self), bytes.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)) }
    }
    guard let pair = _openExistential(type(of: update), do: withClosure) else { return false }
    func apply<Model>(_ t: Model.Type) -> Bool {
        guard fields.allSatisfy({ f in
            func fits<V>(_ type: V.Type) -> Bool {
                f.offset >= 0 && f.offset % MemoryLayout<V>.alignment == 0 && f.offset + MemoryLayout<V>.size <= MemoryLayout<Model>.size
            }
            return _openExistential(f.type, do: fits)
        }) else { return false }
        let p = UnsafeMutablePointer<Model>.allocate(capacity: 1)
        let raw = UnsafeMutableRawPointer(p)
        // Every field value is validated before initializing the native model storage.
        for f in fields {
            func matches<V>(_ v: V.Type) -> Bool { values[f.name] is V }
            guard _openExistential(f.type, do: matches) else { p.deallocate();return false }
        }
        for f in fields {
            func initialize<V>(_ v: V.Type) { raw.advanced(by: f.offset).assumingMemoryBound(to: V.self).initialize(to: values[f.name] as! V) }
            _openExistential(f.type, do: initialize)
        }
        defer { p.deinitialize(count: 1);p.deallocate() }
        let model: Model? = p.pointee
        let delta: (keyPath: PartialKeyPath<Model>, update: Any)? = nil
        withUnsafePointer(to: model) { modelPointer in
            withUnsafePointer(to: delta) { deltaPointer in sgrInvokeUpdate(pair.0, pair.1, modelPointer, deltaPointer) }
        }
        return true
    }
    return _openExistential(modelType, do: apply)
}


@_silgen_name("SGRQueueFactoryCall") private func sgrInvokeFactory(_ code: UnsafeRawPointer, _ context: UnsafeRawPointer?) -> UnsafeMutableRawPointer?

private func sgrStored(_ object: AnyObject, _ name: String) -> Any? {
    guard let field = sgrClassFields(type(of: object)).first(where: { $0.name == name }) else { return nil }
    let pointer = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque()).advanced(by: field.offset)
    func load<T>(_ type: T.Type) -> Any { pointer.load(as: T.self) }
    return _openExistential(field.type, do: load)
}
private func sgrSome(_ value: Any?) -> Any? {
    guard let value else { return nil }
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional ? mirror.children.first?.value : value
}

@objc(SGRNativeHistoryRow)
final class SGRNativeHistoryRow: NSObject {
    private let component: AnyObject
    @objc let view: UIView
    init(component: AnyObject, view: UIView) {
        self.component = component; self.view = view
        super.init()
    }
}

@objc(SGRNativeHistoryRenderer)
final class SGRNativeHistoryRenderer: NSObject {
    @objc(isEditingQueueOf:)
    static func isEditingQueue(of controller: UIViewController) -> Bool {
        guard Thread.isMainThread, NSStringFromClass(type(of: controller)) == "Queue_ViewImpl.QueueViewController" else { return true }
        // Spotify leaves UITableView.editing on for reorder handles even outside
        // its actual Edit mode. Only this native controller field means Edit.
        return (sgrStored(controller, "isEditMode") as? Bool) ?? true
    }

    @objc(currentTrackContainerOf:)
    static func currentTrackContainer(of controller: UIViewController) -> UIView? {
        guard Thread.isMainThread, NSStringFromClass(type(of: controller)) == "Queue_ViewImpl.QueueViewController" else { return nil }
        return sgrSome(sgrStored(controller, "$__lazy_storage_$_currentTrackContainerView")) as? UIView
    }

    @objc(rowInController:title:subtitle:artwork:)
    static func row(in controller: UIViewController, title: String, subtitle: String, artwork: URL?) -> SGRNativeHistoryRow? {
        guard Thread.isMainThread, NSStringFromClass(type(of: controller)) == "Queue_ViewImpl.QueueViewController",
              let field = sgrClassFields(type(of: controller)).first(where: { $0.name == "trackRowFactory" }) else { return nil }
        let metadata = unsafeBitCast(field.type, to: UnsafePointer<UInt>.self)
        // Zero arguments, native Swift convention, escaping, no throws/async.
        guard metadata[0] == 0x302, metadata[1] == 0x4000000 else { return nil }
        let resultType = unsafeBitCast(metadata[2], to: Any.Type.self)
        guard resultType is AnyClass, String(reflecting: resultType).hasPrefix("LegacyUI_ECMCoreKit.ConfigurableComponent<"),
              String(reflecting: resultType).contains(".TrackRowQueue.Model,") else { return nil }
        let pointer = UnsafeRawPointer(Unmanaged.passUnretained(controller).toOpaque()).advanced(by: field.offset)
        let code = pointer.load(as: UnsafeRawPointer.self)
        let context = pointer.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
        guard let raw = sgrInvokeFactory(code, context) else { return nil }
        let component = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        guard ObjectIdentifier(type(of: component)) == ObjectIdentifier(resultType),
              sgrUpdateRow(component, title: title, subtitle: subtitle, cover: artwork),
              let view = Mirror(reflecting: component).children.first(where: { $0.label == "view" })?.value as? UIView else { return nil }
        return SGRNativeHistoryRow(component: component, view: view)
    }
}
