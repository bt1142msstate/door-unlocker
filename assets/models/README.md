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
