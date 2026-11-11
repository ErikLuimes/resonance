# Silicon: the SIDs' dies

The Silicon visualizer renders the dies of the MOS 6581 R3 and the 8580 R5 from
their mask layers, and shows whichever the tune was written for.

## Where the layers come from

Tommi Lempinen redrew the die layer by layer from Michael Huth's microscope
photographs (https://retronn.de/imports/commodore_chips.html). His files are at
http://oms.wmhost.com/misc/ :

| File | What it is |
|---|---|
| `MOS_6581R3_layer_bitmaps.zip` | The five layers (diffusion, polysilicon, buried contacts, contacts, metal), each a 16820 × 14629 one-bit PNG. 1.1 MB. |
| `MOS_6581_R3_blocks.jpg` | His map of which block is where, over a photograph. The 6581's blocks in `SiliconDie` are read off it. |
| `MOS_8580R5_layer_bitmaps.zip` | The 8580's layers, 15012 × 14202; its polysilicon is in two files, which are merged. 0.8 MB. |
| `MOS_8580_R5.jpg` | His photograph of the 8580's die. There's no block map of it: its blocks are placed by eye on this. |

His page on siliconpr0n (https://siliconpr0n.org/archive/doku.php?id=tommi:start)
gives the license for his work as **CC BY-SA** and links to that folder. It
doesn't name a version. Checked 2026-11-10.

## What's in the app

`apple/Resonance/Scenes/SIDDie6581R3.lzfse` (4205 × 3657) and `SIDDie8580R5.lzfse`
(3753 × 3550) are those layers scaled to a quarter and packed, a file a chip, by
`pack-layers.swift` here: four bytes a
pixel for how much of it the diffusion, polysilicon, metal and contacts cover.
As things made from his work they're under the same CC BY-SA license, not the
MIT license the rest of Resonance's own files have. He's credited in the app's
acknowledgments (`apple/scripts/acknowledgments.sh`).

To make it again:

```
swift pack-layers.swift 6581R3 <folder with the unzipped layers> apple/Resonance/Scenes/SIDDie6581R3.lzfse
swift pack-layers.swift 8580R5 <folder with the unzipped layers> apple/Resonance/Scenes/SIDDie8580R5.lzfse
```

The layers themselves aren't in this repository.

## The wear texture

`apple/Resonance/Scenes/SiliconWear.lzfse` is ours, not his: the grain, scratches,
blotches and specks the package's aged materials read. `make-wear.swift` here
makes it, the same way every time:

```
swift make-wear.swift apple/Resonance/Scenes/SiliconWear.lzfse
```

It's shipped rather than worked out when the visualizer opens, which took a third
of a second.

## Things to know

- The layers and the map are half a turn apart: the layers read "6581R3" upright
  in their lower right corner, the map has it upside down in its upper left.
  `SiliconDie` turns the map's places to the layers'.
- The 8580's blocks are our reading of a photograph, by its likeness to the 6581:
  less sure than the 6581's, which are his.
- The 8580's package follows a photograph of one (`Wolf_8580R5_USA.jpg` in his
  folder) for its look; nothing from it is in the app.
- The map doesn't say which of the three voice columns is voice 1. They're taken
  left to right on the map.
- The colors and the lighting are ours, matched by eye to his photographs: the
  layers only say where each material is.
- The bond pads are found on the metal layer (big solid squares near the edges);
  two of the 28 couldn't be told from test structures and are placed by eye. Which
  pad is which pin is our guess: the audio output's is the one beside the output
  amplifier, and the rest follow round in package order.
- Within a block, the bits are lit in even slices along it. Their values are the
  chip's; their exact places and order aren't known from the map.
- The package is a ceramic DIP-28 drawn to scale in die widths, taking the die as
  about 5 mm across. Its look follows photographs of a ceramic 6569 with its lid
  off (retronn.de), not of a 6581; nothing from them is in the app. Its date code
  is made up.
