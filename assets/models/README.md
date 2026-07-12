# Controller 3D Asset

`xiao-nrf52840-sense-official.glb` is derived from Seeed Studio's published
`XIAO-nRF52840 v15.step` model:

- Product documentation: <https://wiki.seeedstudio.com/XIAO_BLE/>
- Official STEP download: <https://files.seeedstudio.com/wiki/XIAO-BLE/seeed-studio-xiao-nrf52840-3d-model.zip>

The STEP assembly was meshed with OpenCascade XCAF so its published part colors
were retained, then consolidated into 12 material-group meshes for efficient web
rendering. The GLB uses millimeters and measures approximately
`22.482 x 4.460 x 17.780 mm`, including the USB-C connector envelope.

`xiao-nrf52840-sense-official.js` is a generated base64 wrapper around the same
GLB. It lets the project page load the exact model when opened directly from the
filesystem without requiring a local web server. The interactive housing model
adds separate long header pins because the purchased XIAO is the pre-soldered
variant installed in a breadboard.

The added header geometry uses a 2.54mm pitch, 0.64mm square posts with lightly
chamfered edges, a 2.54mm insulator, and an 8.2mm modeled post length so the
pins visibly traverse the PCB and enter the breadboard. In the official-model
path, the header assembly is parented directly to the Seeed CAD and centered on
its extracted castellated-hole coordinates instead of using a separate visual
overlay. The pitch and post section follow standard straight male-header
dimensions; the fitted post length should still be checked with calipers before
a final enclosure.

No downloaded LM2596 model is currently bundled. Public CAD models found during
the July 2026 review represent the common approximately 45 x 21 x 13mm module
without the voltmeter display, rather than the purchased Seloky B0DM946DHG
60 x 40 x 10mm module. The viewer therefore uses a dimension-locked detailed
procedural model instead of presenting a mismatched third-party CAD file as the
real part.

No exact XALXMAW B0B28GYYL2 splitter CAD model was located either. The available
WAGO and industrial inline-connector STEP files describe different products.
The viewer therefore models each purchased splitter from its listed
32 x 13.5 x 13mm envelope with three orange levers, two output entries, one
input entry, inspection windows, visible conductor contacts, housing seams, and
coupling tabs. The procedural silhouette follows the listing photography: the
two-output end uses the full body width, the single-input end narrows to an
estimated 8.2mm stem, and all three conductors enter through opposing lengthwise
end faces. The delivered parts should still be checked with calipers before the
final print.
