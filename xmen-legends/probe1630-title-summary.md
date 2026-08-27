# Probe 1630 title-scene summary

Probe 1630 ran the Release runtime after restoring the legacy VCLIP generator,
adding the missing `ret1@0x00108FA8` MPEG helper, and trimming VIF trace volume.
The raw stderr trace was removed after review because it contained no
`xmen-title-world-final`, `xmen-title-raster`, `xmen-title-broad-draw`, or
`xmen-title-draw` records.

The runtime repeatedly loaded `main_back.igb` and attached a scene node to the
same root. The observed active intervals were:

| Attach tick | Detach tick | Node |
| ---: | ---: | ---: |
| 1726 | 1773 | `0x00BB2140` |
| 1923 | 1965 | `0x01004330` |
| 2112 | 2152 | `0x00E044C0` |
| 2298 | 2335 | `0x00C75610` |
| 2480 | 2513 | `0x00C494C0` |
| 2658 | 2692 | `0x00C4D680` |
| 2837 | 2871 | `0x00C4F2D0` |

Every attach came from guest source `0x418714` to target `0x19C140`; every
detach came from `0x4186C4` to `0x19C480`. The root was always `0x00DA1E60`,
with vtable `0x006F41D0`, and each node used vtable `0x006F4870`.

Runtime-owned checkpoints at ticks 2118, 2119, and 2120 showed only the
malformed white X-Men Legends logo on black. Checkpoints from 2190 through
2280 were black and fell outside the 2112-2152 attachment interval. The next
probe should capture several frames *inside* each interval above, especially
2112-2152 and 2298-2335, rather than using the old sparse checkpoint list.

The full event lines and surrounding resource-load trace remain in
`probe1630.out.log`. Probe 1629 retains the six movie-group transitions, and
probe 1628 retains the first successful run past the formerly missing MPEG
helper.
