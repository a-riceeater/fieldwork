# Fieldwork app icon

The mark is a drill formation: ten performer dots on an exact 104-unit grid form
an F. The field-blue tile, white dots and blue accent use the app's existing
design tokens. Flat fills and circles keep the mark legible without illustration,
text, gradients or simulated materials. The mark has equal horizontal padding
and generous vertical padding inside the tile.

`fieldwork.svg` is the editable 1024 × 1024 master. The rounded tile includes
transparent padding for the macOS icon silhouette. All seven PNG sizes in
`apps/macos/Fieldwork/Assets.xcassets/AppIcon.appiconset` are generated from it;
the asset catalog supplies every standard and Retina macOS icon slot.

After editing the SVG, run `./scripts/generate-app-icon.sh` from any directory
(requires ImageMagick 7), then rebuild the app. Xcode's app icon build setting
compiles the catalog into the app bundle and supplies its icon metadata.
