// SPDX-License-Identifier: GPL-2.0-or-later
//
// WinPocket: the iOS display and audio path built on Husk.
//
// SPICE renders the guest by encoding each frame and sending it to an in-app
// client. Husk removes both steps: QEMU's DisplayChangeListener hands over the
// CPU surface, and this view uploads it to a Metal texture the compositor
// already knows how to scale. Audio works the same way -- QEMU writes PCM into
// a lock-free ring and the render callback below drains it.
//
// The backend symbols live in the QEMU library and are resolved by
// UTMHuskBackend when that library is loaded, so every call here is harmless
// before the machine starts (the ring is empty and the frame lock returns NO).
//

#if os(iOS) && !WITH_REMOTE

import AVFoundation
import Metal
import QuartzCore
import SwiftUI
import UIKit

// MARK: - Rendering

/// Presents the guest's surface.
///
/// The layer's drawable is kept at the guest's own pixel size and the view is
/// scaled by Core Animation, so a frame is a straight copy with no shader and no
/// resampling in this process. Touch coordinates divide by the same scale the
/// view is drawn at, which is why the frame rect is the source of truth for
/// input as well as presentation.
final class VMDisplayHuskView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let backend = UTMHuskBackend.shared
    private var commandQueue: MTLCommandQueue?
    private var frameTexture: MTLTexture?
    private var textureGeneration: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false // the view controller maps touches
        isOpaque = true
        backgroundColor = .black
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("Husk display: no Metal device")
            return
        }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // The drawable is guest-sized; 1.0 here keeps the copy 1:1.
        metalLayer.contentsScale = 1.0
        commandQueue = device.makeCommandQueue()
    }

    func start() {
        guard displayLink == nil else {
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A drawableSize that does not match a guest frame would crop the copy,
        // so hold the layer at the guest's size and let CA scale the result.
        if let texture = frameTexture {
            metalLayer.drawableSize = CGSize(width: texture.width, height: texture.height)
        }
    }

    @objc private func step() {
        guard let commandQueue else {
            return
        }
        let sequence = backend.frameSequence()
        guard sequence != 0, sequence != lastSequence else {
            return
        }

        var frame = UTMHuskFrame(pixels: nil, width: 0, height: 0, stride: 0,
                                 bpp: 0, generation: 0, sequence: 0)
        guard backend.lockFrame(&frame), let pixels = frame.pixels,
              frame.width > 0, frame.height > 0, frame.stride > 0 else {
            // Not an error: the guest has not drawn yet, or a resize is in
            // flight. Try again next tick.
            return
        }
        defer {
            backend.unlockFrame()
        }

        let width = Int(frame.width)
        let height = Int(frame.height)

        if frameTexture == nil || textureGeneration != frame.generation {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                      width: width,
                                                                      height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.shaderRead]
            guard let device = metalLayer.device,
                  let texture = device.makeTexture(descriptor: descriptor) else {
                return
            }
            frameTexture = texture
            textureGeneration = frame.generation
            metalLayer.drawableSize = CGSize(width: width, height: height)
        } else if let texture = frameTexture, texture.width != width || texture.height != height {
            return
        }

        guard let texture = frameTexture else {
            return
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: pixels,
                        bytesPerRow: Int(frame.stride))
        lastSequence = sequence

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        let copyWidth = min(width, drawable.texture.width)
        let copyHeight = min(height, drawable.texture.height)
        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                  to: drawable.texture,
                  destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Display controller

/// A window onto the guest's display when the Husk backend is active.
///
/// It owns presentation, viewport gestures and pointer input; keyboard input is
/// shared with `HuskKeyInputView`, because hardware keys arrive through whichever
/// responder is first and UTM overrides that with the view controller itself.
final class VMDisplayHuskViewController: VMDisplayViewController {
    private let backend = UTMHuskBackend.shared
    private let displayView = VMDisplayHuskView(frame: .zero)
    private let keyView = HuskKeyInputView(frame: .zero)
    private var guestSize: CGSize = .zero
    private var sizeTimer: Timer?
    private var pointerIsDown = false

    @Binding private var state: VMWindowState

    init(state: Binding<VMWindowState>) {
        _state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used for a Husk display")
    }

    deinit {
        sizeTimer?.invalidate()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        keyView.frame = view.bounds
        keyView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        keyView.sendKey = { [weak self] qcode, down in
            self?.backend.sendKey(qcode, down: down) ?? false
        }
        view.addSubview(keyView)
        view.addSubview(displayView)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        displayView.start()
        refreshGuestSize()
        // virtio-gpu resizes long after the first frame; poll sparsely rather
        // than take the BQL on every display refresh.
        sizeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGuestSize()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        state.displayViewSize = view.bounds.size
        if state.isDisplayZoomLocked || guestSize == .zero || !state.isViewportChanged {
            fitDisplay()
        } else {
            layoutDisplay()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        displayView.start()
        state.displayViewSize = view.bounds.size
        if state.isDisplayZoomLocked || state.displayScale == 1.0 && state.displayOrigin == .zero {
            fitDisplay()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayView.stop()
    }

    override func showKeyboard() {
        keyView.becomeFirstResponder()
    }

    override func hideKeyboard() {
        keyView.resignFirstResponder()
    }

    /// Called by the hosting representable after the window state changes from
    /// outside (the toolbar's fit action, for example).
    func applyWindowState() {
        state.displayViewSize = view.bounds.size
        layoutDisplay()
    }

    // MARK: Viewport

    private func refreshGuestSize() {
        var width: Int32 = 0
        var height: Int32 = 0
        backend.guestSizeWidth(&width, height: &height)
        guard width > 0, height > 0 else {
            return
        }
        let size = CGSize(width: Int(width), height: Int(height))
        guard size != guestSize else {
            return
        }
        guestSize = size
        if state.isDisplayZoomLocked || state.displayScale == 1.0 {
            fitDisplay()
        } else {
            layoutDisplay()
        }
    }

    private func fitDisplay() {
        let bounds = view.bounds.size
        guard guestSize.width > 0, guestSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return
        }
        let scale = min(bounds.width / guestSize.width, bounds.height / guestSize.height)
        let origin = CGPoint(x: (bounds.width - guestSize.width * scale) / 2,
                             y: (bounds.height - guestSize.height * scale) / 2)
        // Assigning the binding during layout can come straight back as another
        // layout pass, so only write when something actually changed.
        if state.displayScale != scale {
            state.displayScale = scale
        }
        if state.displayOrigin != origin {
            state.displayOrigin = origin
        }
        state.isDisplayZoomLocked = true
        layoutDisplay()
    }

    private func layoutDisplay() {
        guard guestSize.width > 0, guestSize.height > 0 else {
            return
        }
        let scale = max(0.05, state.displayScale)
        displayView.frame = CGRect(origin: state.displayOrigin,
                                   size: CGSize(width: guestSize.width * scale,
                                                height: guestSize.height * scale))
        displayView.setNeedsLayout()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else {
            return
        }
        let newScale = min(8.0, max(0.05, state.displayScale * gesture.scale))
        gesture.scale = 1
        state.displayScale = newScale
        state.isDisplayZoomLocked = false
        layoutDisplay()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else {
            return
        }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        state.displayOrigin = CGPoint(x: state.displayOrigin.x + translation.x,
                                      y: state.displayOrigin.y + translation.y)
        state.isDisplayZoomLocked = false
        layoutDisplay()
    }

    // MARK: Pointer input

    private func guestPoint(for touch: UITouch) -> CGPoint? {
        guard guestSize.width > 0, guestSize.height > 0 else {
            return nil
        }
        let location = touch.location(in: view)
        let scale = max(0.05, state.displayScale)
        var x = (location.x - state.displayOrigin.x) / scale
        var y = (location.y - state.displayOrigin.y) / scale
        guard x >= 0, y >= 0, x < guestSize.width, y < guestSize.height else {
            return nil
        }
        x = min(max(x, 0), guestSize.width - 1)
        y = min(max(y, 0), guestSize.height - 1)
        return CGPoint(x: x, y: y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let point = guestPoint(for: touch) else {
            super.touchesBegan(touches, with: event)
            return
        }
        pointerIsDown = true
        backend.sendPointerX(Int32(point.x), y: Int32(point.y), down: true)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesMoved(touches, with: event)
            return
        }
        // Move with the button state we are in: a drag paints, a hover tracks.
        // A point outside the guest is clamped by QEMU, so it is still sent.
        let location = touch.location(in: view)
        let scale = max(0.05, state.displayScale)
        let x = (location.x - state.displayOrigin.x) / scale
        let y = (location.y - state.displayOrigin.y) / scale
        backend.sendPointerX(Int32(x), y: Int32(y), down: pointerIsDown)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, let point = guestPoint(for: touch) {
            backend.sendPointerX(Int32(point.x), y: Int32(point.y), down: false)
        }
        pointerIsDown = false
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first, let point = guestPoint(for: touch) {
            backend.sendPointerX(Int32(point.x), y: Int32(point.y), down: false)
        }
        pointerIsDown = false
        super.touchesCancelled(touches, with: event)
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !HuskKeyInputView.send(presses: presses, down: true, via: backend) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !HuskKeyInputView.send(presses: presses, down: false, via: backend) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        _ = HuskKeyInputView.send(presses: presses, down: false, via: backend)
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - Keyboard

/// The software keyboard and the hardware one arrive in different shapes: text
/// from `UIKeyInput`, HID usages from `pressesBegan`. Both end at QEMU's QKeyCode
/// names, which the backend resolves against its own table.
final class HuskKeyInputView: UIView, UIKeyInput {
    var sendKey: ((String, Bool) -> Bool)?

    override var canBecomeFirstResponder: Bool { true }

    /// This view exists to hold first-responder status, not to be touched: the
    /// display underneath owns the pointer, so hit testing passes straight
    /// through it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    var hasText: Bool { true }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) {
        for character in text {
            sendCharacter(character)
        }
    }

    func deleteBackward() {
        tap("backspace")
    }

    private func tap(_ qcode: String) {
        _ = sendKey?(qcode, true)
        _ = sendKey?(qcode, false)
    }

    private func sendCharacter(_ character: Character) {
        if character == "\n" || character == "\r" {
            tap("ret")
            return
        }
        if character == " " {
            tap("spc")
            return
        }
        guard let (qcode, needsShift) = Self.characterMap[character] else {
            return
        }
        if needsShift {
            _ = sendKey?("shift", true)
        }
        tap(qcode)
        if needsShift {
            _ = sendKey?("shift", false)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !Self.send(presses: presses, down: true, via: sendKey) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !Self.send(presses: presses, down: false, via: sendKey) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        _ = Self.send(presses: presses, down: false, via: sendKey)
        super.pressesCancelled(presses, with: event)
    }

    @discardableResult
    static func send(presses: Set<UIPress>, down: Bool, via backend: UTMHuskBackend) -> Bool {
        send(presses: presses, down: down) { qcode, isDown in
            backend.sendKey(qcode, down: isDown)
        }
    }

    @discardableResult
    static func send(presses: Set<UIPress>, down: Bool,
                     via sendKey: ((String, Bool) -> Bool)?) -> Bool {
        var handled = false
        for press in presses {
            if let key = press.key, let qcode = hidMap[key.keyCode] {
                _ = sendKey?(qcode, down)
                handled = true
            }
        }
        return handled
    }

    static let hidMap: [UIKeyboardHIDUsage: String] = {
        var map: [UIKeyboardHIDUsage: String] = [:]
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for (index, character) in letters.enumerated() {
            if let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardA.rawValue + index) {
                map[usage] = String(character)
            }
        }
        for (index, name) in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].enumerated() {
            if let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboard1.rawValue + index) {
                map[usage] = name
            }
        }
        for index in 0..<12 {
            if let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardF1.rawValue + index) {
                map[usage] = "f\(index + 1)"
            }
        }
        let rest: [UIKeyboardHIDUsage: String] = [
            .keyboardReturnOrEnter: "ret",
            .keyboardEscape: "esc",
            .keyboardDeleteOrBackspace: "backspace",
            .keyboardTab: "tab",
            .keyboardSpacebar: "spc",
            .keyboardHyphen: "minus",
            .keyboardEqualSign: "equal",
            .keyboardOpenBracket: "bracket_left",
            .keyboardCloseBracket: "bracket_right",
            .keyboardBackslash: "backslash",
            .keyboardSemicolon: "semicolon",
            .keyboardQuote: "apostrophe",
            .keyboardGraveAccentAndTilde: "grave_accent",
            .keyboardComma: "comma",
            .keyboardPeriod: "dot",
            .keyboardSlash: "slash",
            .keyboardCapsLock: "caps_lock",
            .keyboardLeftArrow: "left",
            .keyboardRightArrow: "right",
            .keyboardUpArrow: "up",
            .keyboardDownArrow: "down",
            .keyboardHome: "home",
            .keyboardEnd: "end",
            .keyboardPageUp: "pgup",
            .keyboardPageDown: "pgdn",
            .keyboardDeleteForward: "delete",
            .keyboardInsert: "insert",
            .keyboardPrintScreen: "print",
            .keyboardLeftShift: "shift",
            .keyboardRightShift: "shift_r",
            .keyboardLeftControl: "ctrl",
            .keyboardRightControl: "ctrl_r",
            .keyboardLeftAlt: "alt",
            .keyboardRightAlt: "alt_r",
            .keyboardLeftGUI: "meta_l",
            .keyboardRightGUI: "meta_r",
        ]
        map.merge(rest) { current, _ in current }
        return map
    }()

    static let characterMap: [Character: (String, Bool)] = {
        var map: [Character: (String, Bool)] = [:]
        for character in "abcdefghijklmnopqrstuvwxyz" {
            map[character] = (String(character), false)
            map[Character(character.uppercased())] = (String(character), true)
        }
        let digits: [(Character, String, Character)] = [
            ("1", "1", "!"), ("2", "2", "@"), ("3", "3", "#"), ("4", "4", "$"), ("5", "5", "%"),
            ("6", "6", "^"), ("7", "7", "&"), ("8", "8", "*"), ("9", "9", "("), ("0", "0", ")"),
        ]
        for (digit, name, shifted) in digits {
            map[digit] = (name, false)
            map[shifted] = (name, true)
        }
        let punctuation: [(Character, String, Character?)] = [
            ("-", "minus", "_"), ("=", "equal", "+"),
            ("[", "bracket_left", "{"), ("]", "bracket_right", "}"),
            ("\\", "backslash", "|"), (";", "semicolon", ":"),
            ("'", "apostrophe", "\""), ("`", "grave_accent", "~"),
            (",", "comma", "<"), (".", "dot", ">"), ("/", "slash", "?"),
        ]
        for (base, name, shifted) in punctuation {
            map[base] = (name, false)
            if let shifted {
                map[shifted] = (name, true)
            }
        }
        return map
    }()
}

// MARK: - Audio

/// Plays what the guest produces.
///
/// QEMU's audio thread writes into the husk-audio ring while holding the BQL; a
/// render callback that blocked on that lock would drop the whole stream, not one
/// buffer. The ring is therefore the only thing shared between the two threads,
/// and it is lock-free in both directions.
@MainActor
final class HuskAudioEngine {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else {
            return
        }
        let backend = UTMHuskBackend.shared
        guard backend.isAvailable else {
            logger.error("Husk audio: the QEMU library has no audio backend")
            return
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 48_000,
                                         channels: 2,
                                         interleaved: true) else {
            logger.error("Husk audio: cannot describe the guest format")
            return
        }
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers.first?.mData else {
                return noErr
            }
            _ = backend.pullAudio(data.assumingMemoryBound(to: Int16.self),
                                  frames: Int(frameCount))
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            logger.error("Husk audio: engine failed to start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.source = node
        self.isRunning = true
        logger.info("Husk audio: playing 48 kHz stereo")
    }

    func stop() {
        engine?.stop()
        engine = nil
        source = nil
        isRunning = false
    }
}

#endif
