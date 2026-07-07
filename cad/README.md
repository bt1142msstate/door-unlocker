# Door Unlocker Phase 2 CAD

This folder contains the first-pass 3D-print enclosure model for the Door Unlocker.

Files:

- `phase2-enclosure.scad` - parametric OpenSCAD model with shell, back plate, pockets, and color-coded component blocks.
- `phase2-dimensions.json` - dimension assumptions and clearance values used by the model.

This is a fit model, not a final print-ready product. Before printing a functional version:

- Measure the actual servo body, tabs, cable exit, battery, Wagos, XIAO headers, and buck converter with calipers.
- Confirm the servo arm swing path against the real door handle geometry.
- Decide whether the large LM2596 buck remains inside Phase 2 or is replaced by a smaller low-quiescent regulator/charger board.
- Check overhangs, wall thickness, fastener bosses, strain relief, and battery retention after the fit model is reviewed.

OpenSCAD export:

1. Open `phase2-enclosure.scad` in OpenSCAD.
2. Toggle `show_component_blocks` to `false` before exporting a printable shell.
3. Keep `show_back_plate` enabled if printing the plate and shell as a combined fit mockup, or disable it if exporting the shell only.
4. Use `Design > Render`, then `File > Export > Export as STL`.

The colored component blocks are intentionally for preview and fit checking. They should not be exported as part of the printable enclosure.

Dimension starting points:

- Seeed Studio XIAO nRF52840 Sense: https://wiki.seeedstudio.com/XIAO_BLE/
- INJORA 35kg servo listing used for prototype part identity: https://www.amazon.com/dp/B0B56SN46D
- WAGO 222-413 connector family: https://www.wago.com/us/wire-splicing-connectors/compact-splicing-connector/p/222-413
- Current 2S battery listing used for prototype part identity: https://www.amazon.com/dp/B0DPX3FXN9
- Current LM2596 buck listing used for prototype part identity: https://www.amazon.com/dp/B0DM946DHG

Treat these as layout starting points. The printed fit should be based on measured parts, especially the battery, servo tabs, cable exit, and the exact buck converter board.
