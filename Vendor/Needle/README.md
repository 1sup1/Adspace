# Needle 2 iOS artifacts

The iOS runtime is fetched from the official
[`Cactus-Compute/needle2`](https://huggingface.co/Cactus-Compute/needle2)
repository at the immutable revision below:

```text
17a803d95928ba33d3e9a0160e024d9565b5c3f2
```

`ARTIFACTS.sha256` pins the device library, Apple Silicon Simulator library, and
C header. Both official static archives already embed the model in their
`_needle_weights` section, so the app intentionally does not bundle or call
`needle_load` with a second copy of `needle2.cact`. Run
`mise run needle:ios:fetch` to verify the downloads and create
`Needle.xcframework`. Generated libraries are intentionally ignored by Git; the
revision, checksums, module map, and build script are versioned.

The upstream Simulator archive is ARM64-only, so the generated Xcode project
excludes `x86_64` for Simulator builds. Device builds are also ARM64-only.

The pinned upstream objects declare iOS 26.5 as their minimum OS while this app
still supports iOS 17. The app therefore checks the OS before touching the C
runtime and safely routes to the server GPT fallback below iOS 26.5. The linker
warning remains until Cactus publishes artifacts built with an older deployment
target; lowering the object metadata locally would not make newer API usage safe.

The upstream model card and `LICENSE` at the pinned revision identify these
artifacts as Apache-2.0 licensed.
