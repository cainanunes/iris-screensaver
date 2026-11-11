# Iris screensaver

A macOS screensaver that renders the iridescent field from [caina.design](https://caina.design) natively in **Metal**.

It is one of three ports of the same shader, each kept in sync with a single source of truth:

```
caina.design      src/shaders/iridescent.frag.glsl   SOURCE  GLSL, WebGL (OGL)
iris-shader       main.ts                            PORT    WGSL, WebGPU (Figma)
iris-screensaver  Sources/iris.metal                 PORT    MSL, Metal (macOS)
```

A port is never the source. Visual changes happen in the site's `.glsl` first and are then carried down to the ports.

## Build and install

Requires only the Xcode Command Line Tools.

```sh
./build.sh               # build, ad hoc sign, install to ~/Library/Screen Savers
./build.sh --no-install  # build only
```

Then open System Settings → Screen Saver and pick **Iris**. If it does not show up, quit and reopen System Settings.

## Why no Xcode

`swiftc` compiles the Swift view, and the Metal shader is compiled at runtime with `MTLDevice.makeLibrary(source:)`. That removes the dependency on the `metal` compiler, which ships only with Xcode. The cost is roughly 100 ms on first launch.

## Why IOSurface instead of MTKView

On macOS 26, three render architectures were tested on the same machine:

| Architecture | Preview in Settings | Full-screen screensaver |
|---|---|---|
| `MTKView` as a subview | ✅ | ❌ black, although frames are rendered |
| `CAMetalLayer` as the view's backing layer | ✅ | ❌ same |
| Metal → `IOSurface` → `layer.contents` | ✅ | ✅ |

The full-screen host for legacy screensavers ignores Metal content attached to the view and only composites what arrives as an image, which is the same path WebKit content takes. Handing an `IOSurface` to `layer.contents` uses that path with no copy, since memory is unified.

Rendering uses triple-buffered surfaces with at most two frames in flight. The clock is the host's `animateOneFrame`, not a separate display link.

## Parameters

Tuning lives in `enum IrisParams` in `Sources/IrisScreenSaverView.swift`. Defaults match the website, with `speed` set to 0.35. Edit and run `./build.sh`.

There is intentionally no options panel, because the Options sheet for legacy screensavers is broken on macOS 26. For large displays, `renderScale = 0.5` cuts GPU cost by 4× with an almost free upscale on a smooth gradient, and `fps = 30` halves it.

## Deliberate differences from the source shader

| Website (GLSL) | macOS (MSL) | Reason |
|---|---|---|
| `pow(x, 2.0)` on distances | `sq(x)` (`x * x`) | `pow` is undefined for a negative base inside the bulge radius |
| Live pointer with spring | Pointer fixed at (0.5, 0.5), strength 0 | A screensaver has no pointer; the term stays for fidelity to the source |
| Loose `uniform float`s | One `Uniforms` struct, floats only | No `float2`, so the layout matches Swift without padding |
| WebGL canvas | `IOSurface` / `.bgra8Unorm` | Values written as is, no sRGB conversion, same as the canvas |

## Debugging

Logs use the subsystem `design.caina.iris.screensaver`:

```sh
log show --info --predicate 'subsystem == "design.caina.iris.screensaver"'
```

Without `--info` the output is empty.

## Notes

`.saver` bundles are a legacy API on macOS 26. They work today, with no guarantee for future releases.
