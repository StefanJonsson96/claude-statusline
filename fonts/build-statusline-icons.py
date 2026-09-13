"""Build StatuslineIcons.ttf: the Nerd Font Spotify logo, nudged right to line up with the folder emoji.

The Nerd Font glyph (U+F1BC) is the same size as the 2-cell folder emoji in Windows Terminal but sits
a third of a cell further left. This copies it into a one-glyph font on a free private-use codepoint,
shifted right by a third of the cell width. Windows Terminal uses it as a fallback font.
"""
import os
import sys

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont

SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.expandvars(
    r"%LOCALAPPDATA%\Microsoft\Windows\Fonts\CaskaydiaMonoNerdFont-Regular.ttf"
)
TARGET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "StatuslineIcons.ttf")
SPOTIFY = 0xF1BC
FAMILY = "Statusline Icons"
SHIFT_CELLS = 1 / 3

font = TTFont(SOURCE)
source_cmap = font.getBestCmap()
cell = font["hmtx"][source_cmap[ord(" ")]][0]
codepoint = next(cp for cp in range(0xE100, 0xE200) if cp not in source_cmap)

options = Options()
options.name_IDs = ["*"]
options.hinting = False
options.layout_features = []
options.drop_tables += ["GSUB", "GPOS", "GDEF", "DSIG"]
subsetter = Subsetter(options)
subsetter.populate(unicodes=[SPOTIFY])
subsetter.subset(font)

name = font.getBestCmap()[SPOTIFY]
glyf = font["glyf"]
glyph = glyf[name]
shift = round(cell * SHIFT_CELLS)
if glyph.isComposite():
    for component in glyph.components:
        component.x += shift
else:
    glyph.coordinates.translate((shift, 0))
glyph.recalcBounds(glyf)
advance, _ = font["hmtx"][name]
font["hmtx"][name] = (advance, glyph.xMin)

for table in font["cmap"].tables:
    table.cmap = {codepoint: name} if table.isUnicode() else {}

names = font["name"]
for record in list(names.names):
    if record.nameID in (1, 3, 4, 6, 16, 17, 21, 22):
        names.removeNames(nameID=record.nameID)
names.setName(FAMILY, 1, 3, 1, 0x409)
names.setName("Regular", 2, 3, 1, 0x409)
names.setName(f"{FAMILY} Regular", 3, 3, 1, 0x409)
names.setName(FAMILY, 4, 3, 1, 0x409)
names.setName("StatuslineIcons-Regular", 6, 3, 1, 0x409)

font.save(TARGET)
print(f"{TARGET}\ncodepoint U+{codepoint:04X}, shifted {shift} of {cell} units")
