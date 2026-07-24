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
