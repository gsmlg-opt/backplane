# Appbar version badge

Display a compact pill badge next to the Backplane brand, following the user's supplied reference. Use the same secondary background and content tokens for the badge and its bottom-positioned DuskMoon tooltip; moonlight's secondary palette matches the supplied warm badge. Only development builds append `-dev` to the application version.

The tooltip lists version, environment, Git ref, commit SHA, build time, and release time. Read application version from the running application; capture environment and local Git metadata at compilation, with deployed metadata taking precedence. Build time and release time are distinct; missing release metadata is shown as `Not provided`. Runtime code must not depend on Mix or Git.

Keep the brand link intact and make the badge keyboard-focusable. Preserve unrelated Relayixir/dependency edits. Verify the metadata contract with focused tests, inspect the badge/tooltip in the browser in light and dark themes, and record the metadata boundary in a project-scoped agent note. No commit, push, or release is requested.

The root stylesheet must use the configured admin bundler CSS output at `/assets/css/app.css`; the old `/assets/app.css` artifact bypasses current dev watcher output and lacks new tooltip utilities.

Use an explicit admin profile and application-relative `priv/static/assets` output directory for stylesheet manifest resolution in assembled releases. Refresh generated admin JavaScript assets to include the current DuskmoonPopover hook. JavaScript source-mode migration is outside this UI change.
