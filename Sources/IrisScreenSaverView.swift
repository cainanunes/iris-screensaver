// Iris — protetor de tela do Mac (Metal).
// A aparência vem de Sources/iris.metal, port do .glsl do site caina.design.
// Os parâmetros abaixo são o ponto de partida (defaults do site, speed 0.35 como no vídeo 1080p).
// Para ajustar: editar, rodar ./build.sh, pronto. Não há painel de opções de propósito.
//
// Arquitetura (08/10/2026): Metal renderiza em IOSurfaces e a camada comum da view recebe o
// IOSurface como `contents`. Motivo medido: no host de tela cheia do macOS 26, tanto MTKView
// quanto CAMetalLayer renderizam (quadros no log) mas NÃO são exibidos; no preview, são.
// IOSurface como contents é composto como imagem, pelo mesmo caminho que o WebKit usa.

import ScreenSaver
import Metal
import QuartzCore
import IOSurface
import os.log

private let irisLog = OSLog(subsystem: "design.caina.iris.screensaver", category: "Iris")

enum IrisParams {
  static let amplitude: Float = 1.0
  static let scale: Float = 3.0
  static let speed: Float = 0.35
  static let bandFreq: Float = 2.6
  static let hueOffset: Float = 0.0
  static let saturation: Float = 0.92
  static let highlight: Float = 0.55
  static let gate: Float = 0.32
  static let pressDepth: Float = 0.85
  static let pressRadius: Float = 0.28
  static let facing: Float = 0.7
  static let gravity: Float = 0.6
  static let flow: Float = 0.2
  static let anchor: Float = 0.7
  /// Escala de render relativa ao backing (1.0 = nativo). 0.5 no Studio Display corta o custo em 4×.
  static let renderScale: CGFloat = 1.0
  static let fps: Double = 60
}

// Espelha struct Uniforms em iris.metal, campo a campo, na mesma ordem (só floats: sem padding).
struct IrisUniforms {
  var resX: Float = 1, resY: Float = 1
  var time: Float = 0
  var pointerX: Float = 0.5, pointerY: Float = 0.5
  var pointerStrength: Float = 0
  var amplitude = IrisParams.amplitude
  var scale = IrisParams.scale
  var speed = IrisParams.speed
  var bandFreq = IrisParams.bandFreq
  var hueOffset = IrisParams.hueOffset
  var saturation = IrisParams.saturation
  var highlight = IrisParams.highlight
  var gate = IrisParams.gate
  var pressDepth = IrisParams.pressDepth
  var pressRadius = IrisParams.pressRadius
  var facing = IrisParams.facing
  var gravity = IrisParams.gravity
  var flow = IrisParams.flow
  var anchor = IrisParams.anchor
}

private struct Target {
  let surface: IOSurface
  let texture: MTLTexture
}

@objc(IrisScreenSaverView)
final class IrisScreenSaverView: ScreenSaverView {
  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var pipeline: MTLRenderPipelineState?
  private var targets: [Target] = []
  private var targetIndex = 0
  private var targetSize = CGSize.zero
  private let inflight = DispatchSemaphore(value: 2)
  private var startTime: CFTimeInterval = CACurrentMediaTime()
  private var frames = 0
  private var setupError: String? {
    didSet { if let e = setupError { os_log("Iris setup error: %{public}@", log: irisLog, type: .error, e) } }
  }

  override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    animationTimeInterval = 1.0 / IrisParams.fps
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.contentsGravity = .resize
    layer?.isOpaque = true

    guard let device = MTLCreateSystemDefaultDevice() else {
      setupError = "Metal indisponível"
      return
    }
    self.device = device
    queue = device.makeCommandQueue()

    do {
      let bundle = Bundle(for: IrisScreenSaverView.self)
      guard let url = bundle.url(forResource: "iris", withExtension: "metal") else {
        setupError = "iris.metal não encontrado no bundle"
        return
      }
      let source = try String(contentsOf: url, encoding: .utf8)
      // Compilação em tempo de execução: dispensa o compilador `metal` do Xcode.
      let library = try device.makeLibrary(source: source, options: nil)
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = library.makeFunction(name: "iris_vertex")
      desc.fragmentFunction = library.makeFunction(name: "iris_fragment")
      desc.colorAttachments[0].pixelFormat = .bgra8Unorm
      pipeline = try device.makeRenderPipelineState(descriptor: desc)
      os_log("Iris pipeline ok (%{public}@), preview=%d, bounds=%{public}@", log: irisLog, type: .info,
             device.name, isPreview ? 1 : 0, NSStringFromRect(bounds))
    } catch {
      setupError = "Falha ao compilar o shader: \(error)"
    }
  }

  // MARK: alvos (IOSurface + textura)

  private func ensureTargets() {
    guard let device else { return }
    let scale = (window?.backingScaleFactor ?? 2.0) * IrisParams.renderScale
    let size = CGSize(width: max((bounds.width * scale).rounded(), 1), height: max((bounds.height * scale).rounded(), 1))
    if size == targetSize && targets.count == 3 { return }
    targetSize = size
    targets.removeAll()
    let w = Int(size.width), h = Int(size.height)
    for _ in 0..<3 {
      let props: [IOSurfacePropertyKey: Any] = [
        .width: w, .height: h, .bytesPerElement: 4, .bytesPerRow: w * 4,
        .pixelFormat: UInt32(0x42475241) // 'BGRA'
      ]
      guard let surface = IOSurface(properties: props) else { setupError = "IOSurface falhou"; return }
      let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
      td.usage = [.renderTarget]
      td.storageMode = .shared
      guard let tex = device.makeTexture(descriptor: td, iosurface: surface, plane: 0) else { setupError = "textura IOSurface falhou"; return }
      targets.append(Target(surface: surface, texture: tex))
    }
    layer?.contentsScale = window?.backingScaleFactor ?? 2.0
    os_log("Iris targets %dx%d (preview=%d)", log: irisLog, type: .info, w, h, isPreview ? 1 : 0)
  }

  // MARK: ciclo de vida

  override func startAnimation() {
    super.startAnimation()
    startTime = CACurrentMediaTime()
    ensureTargets()
    os_log("Iris startAnimation, preview=%d, bounds=%{public}@, window=%d", log: irisLog, type: .info,
           isPreview ? 1 : 0, NSStringFromRect(bounds), window == nil ? 0 : 1)
  }

  override func stopAnimation() {
    super.stopAnimation()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    ensureTargets()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    ensureTargets()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    ensureTargets()
  }

  // O host chama isto a cada animationTimeInterval; é o nosso relógio.
  override func animateOneFrame() {
    render()
  }

  override var hasConfigureSheet: Bool { false }
  override var configureSheet: NSWindow? { nil }

  // MARK: render

  private func render() {
    ensureTargets()
    guard let pipeline, let queue, targets.count == 3 else { return }
    if inflight.wait(timeout: .now()) != .success { return }   // GPU atrasada: pula o quadro

    let target = targets[targetIndex]
    targetIndex = (targetIndex + 1) % targets.count

    guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { inflight.signal(); return }

    var u = IrisUniforms()
    u.resX = Float(target.texture.width)
    u.resY = Float(target.texture.height)
    u.time = Float(CACurrentMediaTime() - startTime)
    frames += 1
    if frames == 1 || frames % 600 == 0 {
      os_log("Iris frame %d, %dx%d, t=%.2f", log: irisLog, type: .info, frames, target.texture.width, target.texture.height, u.time)
    }

    enc.setRenderPipelineState(pipeline)
    enc.setFragmentBytes(&u, length: MemoryLayout<IrisUniforms>.stride, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()

    let surface = target.surface
    cmd.addCompletedHandler { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer?.contents = surface
        CATransaction.commit()
        self.inflight.signal()
      }
    }
    cmd.commit()
  }

  // Sem Metal: preto digno, nunca tela quebrada.
  override func draw(_ rect: NSRect) {
    if pipeline == nil {
      NSColor.black.setFill()
      rect.fill()
    }
  }
}
