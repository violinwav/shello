# Fonts

The interface fonts from the UI design (`docs/ui/ui_v1/README.md`, STACK section 7.13), bundled as separate font files. Both are under the SIL Open Font License 1.1; each family's `OFL.txt` sits next to its files and ships in the app with them. `DesignSystem.registerFonts()` registers them at launch.

Only the weights the screens use are bundled: Geist for interface text, JetBrains Mono for data and section headers. To add a weight, take it from the same release archive and add its checksum below.

## Geist 1.8.1

Source: <https://github.com/vercel/geist-font/releases/download/v1.8.1/geist-font-v1.8.1.zip>, SHA-256 `70f42c1452fb6df12ea183e20a65999157354f91d11dac18b4c713e383808ec2` (matches the digest GitHub publishes for the release asset).

| File | Path in the archive | SHA-256 |
| --- | --- | --- |
| `Geist/Geist-Regular.ttf` | `geist-font/Geist/ttf/Geist-Regular.ttf` | `4467c854246d29cf2fe8a18694f4dcd8996439e535d53b260b3bfb34c110175f` |
| `Geist/Geist-Medium.ttf` | `geist-font/Geist/ttf/Geist-Medium.ttf` | `cf90d22c5f12977b06173440f6f564b7e1245aeb48bc4d5fbd82e6cde16abff5` |
| `Geist/OFL.txt` | `geist-font/OFL.txt` | `c683bfbcc7e087f5d37a54ef628f10387c451a83ddc459b151403a164ac46c90` |

## JetBrains Mono 2.304

Source: <https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip>, SHA-256 `6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf` (GitHub publishes no digest for this release; the value matches Homebrew's `font-jetbrains-mono` cask).

| File | Path in the archive | SHA-256 |
| --- | --- | --- |
| `JetBrainsMono/JetBrainsMono-Regular.ttf` | `fonts/ttf/JetBrainsMono-Regular.ttf` | `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f` |
| `JetBrainsMono/JetBrainsMono-SemiBold.ttf` | `fonts/ttf/JetBrainsMono-SemiBold.ttf` | `1b3bfa1ed5665a4ce3f9feb68d2d4e40e70bf8b4b7d9a3edd418f321b4e166a0` |
| `JetBrainsMono/OFL.txt` | `OFL.txt` | `30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad` |
