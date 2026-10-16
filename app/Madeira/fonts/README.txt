Microsoft YaHei fallback face
=============================

`MicrosoftYaHei.otf` is the full Noto Sans CJK SC Regular font from
https://github.com/notofonts/noto-cjk, with its internal Windows family name
changed to `Microsoft YaHei` / `微软雅黑` so Wine's GDI font matching uses it
when a game requests Microsoft YaHei.

This is a glyph fallback for compatibility, not the proprietary Microsoft
font. License: SIL Open Font License 1.1 — see `OFL.txt`.

The font is bundled as an app resource and installed into the Wine prefix's
`drive_c/windows/Fonts` directory at startup, so fresh installations have
Chinese glyphs without downloading anything.
