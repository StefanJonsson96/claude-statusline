# Statusline Icons font

`StatuslineIcons.ttf` holds one glyph on `U+E100`: the Spotify logo from Font Awesome Free, taken from the
CaskaydiaMono Nerd Font (`U+F1BC`) and moved right by a third of a cell so it lines up with the 📁 emoji
on the line above.

`build-statusline-icons.py` rebuilds it (needs `pip install fonttools`):

```powershell
python fonts/build-statusline-icons.py "C:\path\to\CaskaydiaMonoNerdFont-Regular.ttf"
```

Change `SHIFT_CELLS` in the script to move the logo if it doesn't line up on your setup.

## Licenses

The font is a modified version of fonts released under the SIL Open Font License 1.1, and is distributed
under that license:

- [Font Awesome Free](https://fontawesome.com) (glyph): `LICENSE-FontAwesome.txt`
- [Cascadia Code](https://github.com/microsoft/cascadia-code) (base font and metadata): `LICENSE-CascadiaCode.txt`
- [Nerd Fonts](https://www.nerdfonts.com) (patched font): `LICENSE-NerdFonts.txt`

The Spotify logo is a trademark of Spotify AB.
