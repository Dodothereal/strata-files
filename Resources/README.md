# App icon

`AppIcon.icon` is the editable Icon Composer source. `AppIcon.icns` is its exported fallback with standard macOS
sizing and shadow. Both were contributed by [RemoPro](https://github.com/RemoPro) in
[issue #12](https://github.com/cristipufu/strata-files/issues/12), based on Strata’s original purple face.

Open `AppIcon.icon` in Icon Composer to edit the artwork. Keep its ICNS export in sync when changing the design.
The hidden `Strata.png` layer is the contributor’s alignment reference; it is not part of the rendered icon.

`scripts/build.sh` runs `scripts/build-icon.py` before signing. Xcode’s `actool` compiles the layered source into
`Assets.car` for the system’s default, dark and tinted appearances. The bundle also includes the contributed ICNS
fallback, and the compiler’s icon metadata is merged into its `Info.plist`. No Xcode project is needed.
