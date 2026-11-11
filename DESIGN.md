# Backplane UI Implementation Guidelines

This document governs new and changed admin UI in Backplane. Developers, coding agents, and reviewers all follow it. The goal is consistent configuration entry points, list actions, forms, and status feedback. Pages are clear, compact, easy-to-use admin tools, not marketing-style designs.

Existing pages do not yet fully follow these guidelines; they are not a precedent for exceptions in new work. When changing a page, align it within the task's scope; do not start a site-wide refactor without authorization. These guidelines do not change domain state machines, permissions, or API contracts. Explicit task requirements take precedence, and new decisions that should apply going forward must be added to this file.

## 1. Technology and Components

- Use Phoenix LiveView, HEEX, Tailwind CSS 4, and DuskMoon. Business UI belongs in `apps/backplane_admin`; business validation and persistence stay in the owning domain context.
- Prefer `phoenix_duskmoon` `dm_*` components; style with `@duskmoon-dev/core/plugin`. Use DuskMoon Elements as needed, and avoid registering every component when only some are used.
- Do not introduce DaisyUI, other CSS component libraries, or Phoenix's default `core_components.ex`. Do not add a new UI framework, font dependency, or separate design system for a single page.
- Component attributes, slots, and hooks follow the currently installed version. Check existing implementations and dependency sources first; do not guess interfaces from old examples.
- JS hooks handle browser interaction only, such as opening, closing, and focusing a native dialog. Configuration state, validation, and authorization are handled on the server. Reuse existing hooks instead of duplicating them.
- Handle confirmed DuskMoon defects through the upstream issue process in [AGENTS.md](AGENTS.md); do not work around blocking issues with local replacement components.

## 2. Information Architecture and Navigation

Top-level navigation represents existing business domains; specific features live in the matching sidebar menu. Navigation is defined centrally in `Backplane.Admin.Layouts`; pages must not maintain their own menus.

| Domain | Contents |
| --- | --- |
| Dashboard | Health, statistics, usage, and refresh results |
| Llama | Providers, model routing, Decisions, Images, Embeddings, TTS, ASR, Realtime, MiniMax Audio |
| MCP | Managed services, upstreams, Agent MCP, protocol inspection |
| Memory | Records, events, sessions, and Memory configuration |
| Skills | Skill browsing, sources, drafts, and uploads |
| Plugins | Plugin catalog, sources, versions, and distribution |
| Auth | OAuth, RBAC, and authentication audit |
| System | System configuration, credentials, clients, Host Agent, monitor configuration, and logs |

- Provider API capabilities such as OpenAI's belong under **Llama**; do not add an **API Proxy** top-level menu. The current OpenAI capability pages use `/llama/openai/:kind`.
- MiniMax-specific audio configuration is explicitly named **MiniMax Audio** and kept separate from OpenAI TTS/ASR/Realtime; audio models must not be mixed into chat model menus or catalogs.
- Configuration pages manage configuration; the Dashboard shows runtime data. For example, API Usage under System manages accounts, while API Usage under Dashboard shows usage and refresh.
- Within a domain, use a consistent route prefix, sidebar highlighting, and detail-page ownership. Changing an existing public URL requires an explicit compatibility redirect and verification.
- Reuse the shared desktop sidebar and mobile navigation; preserve collapsing, session preferences, active items, and scroll behavior. Pages must not add duplicate sidebar titles or store their own collapse state.

## 3. Page Structure and Visuals

- A page presents, in order: a title and short description, primary actions, filters (if any), then the list or main content. Each page has one `h1`, and the title names the business object.
- The primary action on a list page is **Add**, placed in the title area; the active surface has only one primary action. Once a modal is open, Save is the primary action inside it.
- Use the shared layout's `max-w-7xl` content bounds, responsive padding, and `min-w-0`. Content groups usually use `space-y-6`, with `gap-2` / `gap-4` inside groups. Avoid redundant nested containers and meaningless cards.
- Reuse the existing fonts. Page titles are usually `text-3xl font-bold`; descriptions use `text-sm text-on-surface-variant`; metadata uses `text-xs`; model IDs, paths, and protocol fields use a monospace font.
- Use DuskMoon semantic tokens: pages use `bg-surface text-on-surface`, cards use surface containers, and descriptions use `text-on-surface-variant`. Backgrounds and foregrounds must be paired.
- Primary actions use `primary`, ordinary actions use `outline` / `ghost`, and destructive actions use `error`. `success`, `warning`, `error`, and `info` express status only.
- New pages must not hard-code colors or use Tailwind's fixed palette. Follow the shared layout and Appearance theme settings; do not copy existing centralized brand variables or compatibility rules into pages.
- Support both `sunshine` and `moonlight`; do not pin a theme within a page. Preserve keyboard focus styles and respect `prefers-reduced-motion`.

## 4. Lists and Table Actions

- Prefer `dm_table` for structured configuration, with clear column names, readable status, and a separate **Actions** column; `hover` and `zebra` may be used to improve scanning.
- **All table actions use icon buttons**, not rows of Edit / Enable / Delete text buttons. Page-level Add and modal Save / Cancel keep their text labels.
- Buttons use `dm_btn`; icons use `dm_mdi` / `dm_bsi`. Buttons in the same table share size and shape, usually compact circular buttons; never make an unlabeled SVG alone the click target.
- Every button needs an accessible name and a tooltip. The `aria-label` includes the action and the object, for example `Edit openai route`; the tooltip is short, for example `Edit`; `sr-only` text may be added. Tooltips work on both hover and keyboard focus.
- The trigger attributes returned by `dm_tooltip` must be taken with `:let` and passed to the actual button; do not merely wrap the button in the component and lose the attributes.
- Navigation actions pass `patch` / `navigate` / `href` to `dm_btn` directly; do not wrap `dm_btn` in `<.link>`. A `dm_btn` with neither tooltip attributes nor a link renders `el-dm-button`, which ignores `shape` (duskmoon-dev/duskmoon-elements#89).
- Action order is edit, enable/disable, other business actions, then delete. Common icons: edit `pencil`, disable `pause`, enable `play`, delete `delete`.
- The enable/disable button expresses **the action it will perform**: an enabled item shows Disable, a disabled item shows Enable. The current state appears as a text badge in the Status column and must not rely on color alone.
- Delete uses destructive styling and requires confirmation. The confirmation states the object and the impact; cancelling must not trigger a write.
- Row actions keep stable, unique DOM IDs. Asynchronous actions need a visible in-progress state and must prevent duplicate submission; a failed request must never appear successful.
- An empty list states that nothing is configured yet and points to Add. "No search results" and "nothing configured yet" get different messages; when pagination or filters exist, their state must remain understandable.

Icon button example (adjust the accessible name to the business object):

```heex
<.dm_tooltip :let={tooltip_attrs} content="Edit" position="bottom">
  <.dm_btn
    {tooltip_attrs}
    id={"edit-service-#{service.id}"}
    type="button"
    size="xs"
    shape="circle"
    variant="outline"
    aria-label={"Edit #{service.provider.name} route"}
    phx-click={JS.push("edit", value: %{id: service.id}) |> JS.push_focus()}
  >
    <.dm_mdi name="pencil" class="h-4 w-4" />
    <span class="sr-only">Edit</span>
  </.dm_btn>
</.dm_tooltip>
```

## 5. Add / Edit Modal Forms

- Configuration lists create items through **Add → modal form**, and the edit icon opens the same kind of form. Do not keep a full creation form permanently above a list. Dedicated workflows or complex detail editing must document their interaction design separately.
- Use `dm_modal` with native dialog behavior; the title distinguishes Add / Edit and names the object. Do not stack your own fixed overlays to imitate a modal.
- On open, focus the first sensible input; Tab navigates within the modal; on close, focus returns to the triggering button. Support Cancel, the close button, and Escape.
- Cancel, close, and Escape all discard unsaved values and clear errors; the next Add must open a clean form with nothing left over from the previously edited object.
- On successful save, close the modal, refresh the list, and show success feedback. On validation failure, keep the input and the modal open and show correctable errors. Never clear the form or close the modal on failure.
- LiveView controls whether the form exists and which object is being edited; the dialog's browser state is coordinated through components/hooks. A DOM patch must not unexpectedly close a form that is still valid.
- Every field has an explicit label; hints explain format, units, required limits, and optionality. A placeholder cannot replace a label. Use existing components such as `dm_input`, `dm_select`, and `dm_textarea`.
- Forms explicitly use `phx-submit`; non-submit buttons set `type="button"`. While submitting, lock the save action and show progress text to prevent repeated submission.
- Forms collect only the information that configuration requires. When the connection address and credentials are managed by a Provider, capability forms select the Provider instead of storing the endpoint or key again.

## 6. Default Enablement and State Management

- **New configuration that has an enabled/active state is enabled by default. Creation forms do not show an enable/disable field, checkbox, switch, or hidden state field.**
- The creation default must be consistent across the domain schema/context and the database default; do not rely only on front-end prefill. Form handlers accept only permitted fields, so an extra submitted enabled value cannot bypass the rule.
- After saving, state is changed through the list's enable/disable icon; ordinary Edit forms also have no enable switch, and editing other fields must preserve the existing state.
- Changing a default affects only future creations; do not bulk-change the enabled/disabled state of existing configuration.
- Distinguish configured enablement from actual availability. For example, if a route is enabled but its Provider is disabled or its credential is unavailable, show the specific reason instead of merging both into one success state.
- This convention applies to configuration enablement. Connection results, job execution status, OAuth authorization status, and similar states still come from the actual business process; a default must never fabricate "connected" or "authorized".

## 7. Feedback, Copy, and Data Boundaries

- The UI keeps its current English terminology; the same object has the same name in menus, titles, buttons, and hints. Use short action verbs and specific errors, and avoid exposing irrelevant implementation details.
- Distinguish loading, empty, success, failure, and stale data; asynchronous refresh must not block the whole page. Errors must not be masked by empty lists, fabricated zero values, or old success messages.
- Show state in the relevant area: form errors inside the modal, action results through the shared flash/alert. Keep a path for the user to correct or retry.
- Opening a configuration page, an Add/Edit modal, or an ordinary save must not implicitly run paid API probes; connection tests, refreshes, and other external operations use explicit, separate actions.
- Configuration pages show credential names or references and never echo plaintext keys. Logs, audit records, and error messages must not contain secrets or raw sensitive requests; dedicated flows such as one-time credential issuance follow their existing contracts.

## 8. Responsive Layout and Accessibility

- Verify at least a desktop viewport and a mobile viewport about 390px wide. The page as a whole must not overflow horizontally because of long URLs, model IDs, or tables; wrap long text where needed.
- Wide tables scroll inside their own `overflow-x-auto` container, keeping understandable column headers and the actions column; do not solve mobile layout by hiding key actions.
- Form fields use a single column on narrow screens; modals are constrained to the viewport height, their body scrolls, and Save / Cancel remain reachable.
- Native buttons, links, form labels, heading levels, and `aria-current` must keep correct semantics. Every action is usable by keyboard, and icon buttons must not depend on hover to be understood.
- Tooltips, menus, confirmations, and modals must not be clipped by table scroll containers. Browser verification must actually open, focus, and close them; checking that nodes exist in the HTML is not enough.

## 9. Implementation References and Acceptance

Refer to the matching responsibilities in the currently installed version and the following code; do not copy whole pages blindly:

| Location | Reference for |
| --- | --- |
| `apps/backplane_admin/lib/backplane/admin/components/layouts.ex` | Navigation definitions, grouping, and active items |
| `apps/backplane_admin/lib/backplane/admin/components/layouts/` | Shared page shell and responsive navigation |
| `apps/backplane_admin/lib/backplane/admin/live/openai_proxy_live.ex` | Add/Edit modal, default enablement, separate enable/disable, and icon Actions |
| `apps/backplane_admin/assets/js/hooks/openai_service_modal.js` | Coordinating the native dialog with the LiveView lifecycle |
| `apps/backplane_admin/assets/css/app.css` | Themes, shared styles, and documented compatibility handling |
| `apps/backplane_admin/test/backplane/admin/live/openai_proxy_live_test.exs` | Regressions for create, edit, enable/disable, cancel, validation, and state isolation |

For behavior changes, verify according to the scope of impact:

- Navigation ownership and the current item are correct; there are no duplicate entry points or unexpected top-level menus.
- Add/Edit opens the correct form, cancel writes nothing, success closes the modal, and validation failure keeps the input.
- New items are enabled by default; editing preserves the enable/disable state; list icons perform the correct action and have accessible names.
- Delete requires confirmation; save and asynchronous actions prevent duplicate submission; list and error feedback match the actual result.
- Desktop, mobile, both themes, and keyboard operation work; real assets and hooks load successfully, and LiveView is connected.
- Run the relevant LiveView/domain regressions, format checks on changed files, and appropriate compile/asset checks. DOM tests cannot prove that dialog focus, Escape, tooltips, or mobile scrolling work; those need browser verification.

Documentation-only changes need only documentation checks. When delivering, state what was actually verified and what was not; never describe existing pages or checks that were not run as meeting the guidelines site-wide.
