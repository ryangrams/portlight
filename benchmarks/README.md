# Portlight encoding and pacing measurements

These measurements explain and address a real implementation inefficiency. They **do not reproduce the user's exact screen content or measure the user's actual connection**. Fewer colors alone do not predict smaller compressed packets or smoother viewing.

## What changed

Version 0.1 quantized grayscale into three equal RGB channels, then encoded an 8-bit-per-channel RGB PNG (PNG color type 2). It therefore still fed a 24-bit RGB image to the PNG codec despite using only sixteen values. Version 0.2 retains exactly the same integer luminance and sixteen intensity levels, packs two 4-bit grayscale samples into each byte, and uses ImageIO's standard grayscale PNG writer (color type 0, bit depth 4). Apple Accelerate performs the luminance matrix operation; the compact representation is also used for changed-pixel comparisons.

Odd pixel offsets and odd image widths are explicitly repacked before PNG encoding. This avoids a sub-byte cropping discrepancy found by the exact-pixel test. ImageIO rendering of the old RGB PNG and new packed PNG is pixel-identical. All PNG/JPEG wire headers remain compatible; the codec is still `png`, and no custom decompressor is required.

The previous acknowledgment window also allowed only four image packets in flight. A changing 1920×1080 display can produce forty 256-pixel tiles: four packets forced roughly ten sequential ACK batches for one image. The new window permits up to 32 packets **and** limits in-flight image bytes to 2 MiB. A larger initial image may travel alone; the total pending-image limit stays 32 MiB. Unsent work is retired on subscription change, and control responses remain separately bounded. Images are still dropped before encoding when the prior display update is outstanding; the change does not create an unbounded video backlog.

Small PNG updates no longer cancel a pending full lossless refresh after Automatic mode used JPEG. This preserves sharp text once motion has stopped.

## Encoder comparison

Measured September 9, 2026 on an **Apple M3 Max, macOS 15.7.3 (24G419)**, using the native Swift compiler with `-O`, Apple Silicon target and the same system ImageIO/Accelerate libraries. Every mode and encoder received the same precomputed 1920×1080 source frames, twelve frames per run, three runs. Framework initialization was warmed separately; every run began with a fresh display encoder, so initial full-image payload is included. Text & controls (`desktop`) policy was fixed for every color mode.

The generated workloads cover CoreText labels and flat controls, unchanged content, moving gradients, changing random noise, and a moving graphic pattern. Random noise is deliberately difficult to compress; it is not a claim about ordinary YouTube content. Generation, ScreenCaptureKit capture, network transfer, TLS and viewer decoding are excluded from this encoder-only measurement. CPU time uses `getrusage`; wall timings separately cover rasterization/allocation, quantization, differences and codec work.

| Grayscale workload | Median encode ms, before → after | CPU ms/input frame¹, before → after | Mean PNG kB/input frame, before → after | Payload reduction |
|---|---:|---:|---:|---:|
| Changing text / controls | 5.19 → 1.75 | 8.40 → 1.83 | 13.52 → 6.02 | 55% |
| Unchanged controls | 2.63 → 1.57 | 5.92 → 1.69 | 6.98 → 3.39 | 51% |
| Moving gradients | 44.29 → 3.29 | 44.02 → 3.18 | 73.59 → 27.27 | 63% |
| Changing random noise | 79.73 → 17.56 | 79.52 → 18.07 | 2220.31 → 948.28 | 57% |
| Moving graphic pattern | 45.23 → 3.66 | 45.43 → 3.65 | 102.95 → 50.01 | 51% |

¹ CPU values are the median of three run means.

The unchanged-controls row includes one initial image per run; **subsequent unchanged frames produce zero image bytes**. Median encode time and mean CPU/payload are different statistics, so initial-image costs affect them differently. Complete per-mode timings, p95 values, bytes and PNG format inspection are in [encoder-1080p.json](results/encoder-1080p.json).

Baseline grayscale was not slower at CPU encoding on these inputs. However, its compressed payload was **about 12% larger than 256 colors for moving gradients and 28% larger for the moving graphic pattern**. The spatial patterns produced by luminance quantization compressed differently from RGB332. On a constrained connection that can make 256 colors smoother even though it has more possible colors. The new compact grayscale output was smaller in every generated workload measured here; this is not a universal ordering guarantee for arbitrary images.

For motion/gradient grayscale, PNG codec work fell from approximately 42 ms/input frame to 2 ms; quantization fell from approximately 1.9 ms to 1.3 ms. The dominant saving is the compact grayscale PNG representation, not merely faster arithmetic. Removing grayscale checks from the other per-pixel paths also reduced 256-color/16-bit conversion overhead without changing their encoded image bytes. Full-color and explicit JPEG output remain unchanged; timing differences near one percent should be treated as measurement noise.

## Real WebSocket test with delayed ACKs

This test starts the actual ad-hoc-signed Portlight Host executable in loopback-only fixture mode and uses its real TLS, authentication, subscriptions, tile encoding, queues and WebSocket transport. A generated changing-stripe image makes the whole FHD display change. The client delays each application frame acknowledgment by **20 ms**. Requested capture rate is 15 fps, application bandwidth limit 4,000 kbit/s, duration five seconds per case; audio is off. Fixture generation is timer-driven and scheduling overhead means the offered/achieved rate may be below the request.

**Both window sizes use the optimized encoder. Only the packet window changes**, isolating the queue effect from the grayscale codec change.

| Color mode | Complete updates/s, 4 packets | Complete updates/s, 32 packets | Median ping ms, 32 packets | Maximum ping ms, 32 packets |
|---|---:|---:|---:|---:|
| Grayscale · 16 shades | 3.39 | 12.51 | 1.11 | 4.02 |
| 256 colors | 3.38 | 6.56 | 0.53 | 4.54 |
| 16-bit color | 2.99 | 6.76 | 0.56 | 3.19 |
| Full color | 3.20 | 6.73 | 0.55 | 3.07 |

All eight cases retired old image revisions when pause was acknowledged. The largest sampled pending-image queue was below 57 kB. Ping responses stayed responsive during streaming. Raw results are in [delayed-ack-loopback.json](results/delayed-ack-loopback.json).

This is an actual local transport test with deliberate application ACK delay, **not a physical WAN RTT, a network bandwidth shaper, or native viewer decode measurement**. No studio screen was captured and no remote input was injected. It demonstrates the ACK-window bottleneck and verifies bounded/pause-safe behavior; it does not establish a guarantee for the user's VPN or Windows hardware.

## Fixed-input pacing model

[Paced encoding-only results](results/paced-encoding-only.json) hold the original four-packet window fixed while comparing real old/new encoder calls. [Combined pacing results](results/paced-1080p.json) add the new 32-packet/2-MiB window. These use exactly timed 15-fps generated inputs over a ten-second simulated session, a 4-Mbit/s application token bucket, twenty-millisecond ACK delay, and the host's drop-before-encode rule. Encoding time and packet sizes are measured; transport scheduling is explicitly simulated. Source frame generation, native viewer decoding, packet loss and physical TCP serialization are not simulated. Treat these as controlled diagnostic models, not observed remote-session frame rates.

## Reproduce

From this folder:

```sh
./run_encoder.sh --frames 12 --repeats 3 --output results/encoder-1080p.json
./validate_encoder.sh
./run_paced.sh
../server-macos/build.sh --test
../.test-venv/bin/python delayed_ack.py
../.test-venv/bin/python ../tests/run_e2e.py
```

The Python tools need `websockets` (and the shared end-to-end test also needs Pillow). The encoder/validation tools use only Apple's system frameworks and compiler. `BaselineTileEncoder.swift` is the frozen pre-optimization implementation with timing instrumentation, retained solely to make before/after comparisons reproducible. The baseline and packed PNG files in `results/` contain generated pixels and are decoder compatibility fixtures.

Validation covers exact grayscale output, true four-bit PNG headers, odd dimensions and crop offsets, unchanged-frame suppression, byte-identical 256-color/16-bit/full-color PNG and JPEG output, and lossless refresh after both broad motion and a later small PNG update. The shared real-server end-to-end suite covers monitor selection, scaling, colors, ROI, pause, stale revisions, authentication and control responsiveness. Windows WIC and native macOS viewer checks are recorded by the application's cross-platform validation suite; this folder alone does not imply that every Windows target was run locally.

The host's optional `stats` messages now expose average raster/quantization/diff/codec times, pending image bytes, encoded input count and frames skipped due to backpressure. These counters make future diagnosis on the actual studio content possible without guessing from the color-mode label.
