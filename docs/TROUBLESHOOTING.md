# Troubleshooting

## NES game reports “Core rejected ROM”

FCEUmm expects ordinary `.nes` content to use the iNES or NES 2.0 container format. The first four bytes should normally be `4E 45 53 1A` (`NES` followed by `0x1A`), within a 16-byte header.

A headerless dump may be rejected with only a generic content-load error. Common causes include:

- normalization against a headerless DAT set
- a raw PRG/CHR dump renamed to `.nes`
- a patching or trimming tool that removed the header
- selecting the wrong file from an archive
- a filename extension that does not match the payload
- a stale client cache left behind after the server copy was corrected

Check the exact bytes served by RomM, not only the source file used during import. Compare the downloaded byte count with RomM’s `fs_size_bytes`, verify the magic bytes, and rescan RomM metadata after replacing a file. RommpleTV automatically discards a cached copy when its size differs from current RomM metadata, forcing a fresh download.

Only repair or replace content you are legally entitled to use. Mapper and mirroring fields are content-specific; do not add an arbitrary header copied from another game.

## PlayStation game says a BIOS file is missing

RommpleTV uses only the three standard core-recognized BIOS images and names the exact one it
needs: `scph5501.bin` for USA, `scph5500.bin` for Japan, `scph5502.bin` for Europe/PAL. A game
whose region RomM has not scraped asks for all three.

Each must be present in your RomM firmware library for the PlayStation platform, marked verified,
524288 bytes, and matching the published MD5. RommpleTV names every unresolvable image in one
message, so a server missing two of three tells you both at once rather than one per attempt.

`openbios.bin`, `ps1_rom.bin` and `PSXONPSP660.BIN` are deliberately not used — they require the
core's Override BIOS option, which this build does not enable. Note also that several firmware
entries can share an MD5 under different names (`scph5552.bin` duplicates `scph5502.bin`, for
example); selection is by recognized filename, never by checksum, so an alias will not stand in.

## A multi-disc game shows the wrong number of discs

Before transferring anything, RommpleTV lists the discs it read from RomM's `sibling_roms`
grouping and offers **Not one game — play this disc only**. Use it when a metadata group holds
several separate games rather than one multi-disc title — a compilation, or a numbered demo
series. Disc grouping is inferred from filenames, and no filename rule can distinguish "Disc 1 and
Disc 2 of one game" from "two separately numbered products" with certainty, which is why the set
is shown rather than assumed.

## Change Disc is missing from the pause overlay

Resume and pause once more first: the core may register its disc-control interface after the first
frame, and the check runs again each time the overlay opens.

If it still says the discs cannot be changed, the note prints two numbers — how many discs the
prepared playlist holds and how many the core reports. When those disagree, switching is disabled
rather than risk sending you to a disc you did not choose. Relaunching rebuilds the same playlist,
so if the numbers repeat, that game's discs cannot be changed on this build.

## A game refuses to start, saying the core will not take its saved card

The stored memory card and the size the core expects disagree. This is refused rather than played
through, because starting on a blank card lets the next automatic save overwrite the real one and
upload the blank copy. Nothing on the device or the server is changed when this happens.

There is currently no in-app way to clear a stored card, so a game in this state stays unlaunchable
until the app is reinstalled. If you hit it, that is worth reporting rather than working around.
