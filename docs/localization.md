# Language

The local OpenCodex build supports Korean and English. It follows the app language chosen by
macOS and falls back to English when no translation is available. Restart the app after changing
its language.

Korean covers the dashboard, usage and quota labels, reset countdowns, Customize, Settings,
provider links, notifications, tooltips, accessibility labels, and common connection errors.
Provider and model names keep their original spelling. Provider-specific messages without a
translation, including messages returned directly by a server, remain in their original language.
CLI and local HTTP API output, saved identifiers, and logs are unchanged.

## Maintaining Translations

The translation table is `assets/Localization/ko.lproj/Localizable.strings`. SwiftUI literal labels
use it directly. Runtime display strings use `L10n.display`; known value phrases are rebuilt from
translated templates. Add translations at the display boundary, rather than translating data
before it is saved or returned through the API. Keep placeholder order and counts consistent.

`script/build_and_run.sh` copies the language resources into the app and declares the supported
languages. This is the packaging path used by the local fork. `script/release.sh` does not yet
package these resources; release packaging needs the same changes before distributing a release.
Running the executable with `swift run` alone does not package the translation table.

Run `swift test --filter L10nTests` and `plutil -lint
assets/Localization/ko.lproj/Localizable.strings` after updating translations. Rebuild and restart
the packaged app to check the actual interface.
