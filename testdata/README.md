# Test fixtures

- `exif-orientation-{5,6,8}.jpg` — 64×32 JPEGs with red, blue, green and white
  quadrants (top-left, top-right, bottom-left, bottom-right), each with an EXIF
  APP1 segment whose orientation tag is 5, 6 or 8. Used by
  `source/nano/attachment.d` to check that the macOS `sips` encoder rotates
  the pixels, not just the reported dimensions.
