// Appended to the production Swift file for access to private ABI helpers.
// These are owned fixtures, never substitutes for Spotify UI screenshots.
private enum TrackRowQueue {
    enum Restriction { case isExplicit, is19AndOverOnly, none }
    enum PlayState { case playing, paused, none }
    struct Collaborator { let name: String; let imageUrl: URL? }
    struct Model {
        var name: String; var subtitle: String; var coverArt: URL?
        var restriction: Restriction; var isPlayable: Bool; var playState: PlayState
        var isSelectorVisible: Bool; var isReordering: Bool; var isSelected: Bool; var isRecommendation: Bool
        var collaborators: [Collaborator]
        var isMusicVideo: Bool; var willPlayAsVideo: Bool; var isVideoBadgeVisible: Bool
        var isQueuedBadgeVisible: Bool; var isPlayButtonVisible: Bool; var animated: Bool; var isKallax: Bool
    }
}
private final class ABIComponent<M> {
    let view = UIView()
    let _update: (M?, (keyPath: PartialKeyPath<M>, update: Any)?) -> Void
    init(_ update: @escaping (M?, (keyPath: PartialKeyPath<M>, update: Any)?) -> Void) { _update = update }
}
private final class ABILifetime {
    static var made = 0, destroyed = 0
    init() { Self.made += 1 }
    deinit { Self.destroyed += 1 }
}
private final class ABIFactoryOwner: NSObject {
    let factory: () -> ABILifetime
    override init() {
        let captured = NSObject()
        factory = { _ = ObjectIdentifier(captured); return ABILifetime() }
        super.init()
    }
}
private var abiChecks = 0
private func abiCheck(_ value: Bool, _ message: String) {
    abiChecks += 1
    if !value { NSLog("FAIL queue-abi: %@", message); exit(1) }
}
private func runABI() {
    var received: TrackRowQueue.Model?
    var updates = 0
    let component = ABIComponent<TrackRowQueue.Model> { model, delta in
        abiCheck(delta == nil, "native generic delta is Optional.none")
        received = model;updates += 1
    }
    let artwork = URL(string: "spotify:image:fixture")!
    abiCheck(sgrUpdateRow(component, title: "한국어 긴 제목", subtitle: "아티스트", cover: artwork), "construct native typed model and invoke generic closure")
    abiCheck(received?.name == "한국어 긴 제목" && received?.subtitle == "아티스트", "native String fields survive native model destruction")
    abiCheck(received?.coverArt == artwork, "URL optional uses native layout")
    abiCheck(received?.restriction == TrackRowQueue.Restriction.none && received?.playState == TrackRowQueue.PlayState.none, "native zero-payload enum cases are none")
    abiCheck(received?.isPlayable == true && received?.isSelectorVisible == false && received?.isReordering == false && received?.isPlayButtonVisible == false, "history is playable without native edit/reorder/play-button states")
    abiCheck(received?.collaborators.isEmpty == true, "empty array has the exact native element type")
    for i in 0..<100 {
        let title = String(repeating: "긴 가사 제목 \(i) ", count: 100)
        abiCheck(sgrUpdateRow(component, title: title, subtitle: "", cover: nil), "repeated native update")
        abiCheck(received?.name == title && received?.coverArt == nil, "long string and Optional.none preserve ARC ownership")
    }
    abiCheck(updates == 101, "one native callback per successful update")
    var unexpected = 0
    let wrongModel = ABIComponent<Int> { _, _ in unexpected += 1 }
    abiCheck(!sgrUpdateRow(wrongModel, title: "", subtitle: "", cover: nil) && unexpected == 0, "unknown native model is rejected before invocation")
    // Exercise the exact production swiftcall factory bridge: concrete Swift
    // class reference return, retained result and captured Swift closure context.
    for _ in 0..<100 {
        autoreleasepool {
            let owner = ABIFactoryOwner()
            // Read the stored closure before generic reabstraction, just like
            // QueueViewController.trackRowFactory. withUnsafeBytes(of: factory)
            // itself reabstracts the function result and is not the native ABI.
            let field = sgrClassFields(type(of: owner)).first(where: { $0.name == "factory" })!
            let pointer = UnsafeRawPointer(Unmanaged.passUnretained(owner).toOpaque()).advanced(by: field.offset)
            let pair = (pointer.load(as: UnsafeRawPointer.self), pointer.load(fromByteOffset: 8, as: UnsafeRawPointer?.self))
            let raw = sgrInvokeFactory(pair.0, pair.1)!
            let value = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
            abiCheck(value is ABILifetime, "factory returns the real concrete class, without existential reabstraction")
        }
    }
    abiCheck(ABILifetime.made == 100 && ABILifetime.destroyed == 100, "native factory retains/releases balance")
    NSLog("PASS queue-abi: %d checks (concrete factory return, ARC, exact model fields, native enum/array/optional, generic update, unknown-model rejection)", abiChecks)
    exit(0)
}
@objc(SGRABIAppDelegate) final class SGRABIAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds);window?.rootViewController = UIViewController();window?.makeKeyAndVisible()
        DispatchQueue.main.async { runABI() }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(SGRABIAppDelegate.self))
