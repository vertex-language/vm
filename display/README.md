# vm/display

A guest's screen.

- **`Framebuffer`**: guest RAM the host reads, with its mode (size,
  stride, pixel format) and a generation counter. `Snapshot()` copies it out
  as BGRA rows for `ui/window`.
- **`Ramfb`**: configured by the firmware through fw_cfg's `etc/ramfb`.
  UEFI turns it into GOP, and Windows' Basic Display driver keeps using it.
  It's the smallest path to a Windows desktop with no display driver.

virtio-gpu (for Linux desktops) will be `virtio.Gpu` in `vm/virtio`. Showing a
framebuffer belongs to `ui/window`, or to a VNC/RDP server, never to this
package.
