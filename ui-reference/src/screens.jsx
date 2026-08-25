import { useState } from "react";
import {
  ArrowElbowDownLeft,
  ClipboardText,
  Copy as CopyIcon,
  FileText,
  FolderOpen,
  ImageSquare,
  Lightning,
  LinkSimple,
  Lock,
  MagnifyingGlass,
  Star,
  Warning,
  X,
} from "@phosphor-icons/react";
import { AppIcon, Icon } from "./icons.jsx";

const NAV_ITEMS = [
  ["general", "gear", "General"],
  ["shortcuts", "keyboard", "Shortcuts"],
  ["features", "grid", "Features"],
  ["extensions", "puzzle", "Extensions"],
  ["permissions", "hand", "Permissions"],
  ["privacy", "lock", "Privacy"],
  ["updates", "update", "Updates"],
  ["advanced", "sliders", "Advanced"],
  ["about", "info", "About"],
];

function KeyCap({ children }) {
  return <kbd>{children}</kbd>;
}

function PrimaryButton({ children, icon, onClick }) {
  return <button className="primary-button" onClick={onClick}>{icon && <Icon name={icon} size={15} />}{children}</button>;
}

function SecondaryButton({ children, danger = false, onClick }) {
  return <button className={`secondary-button ${danger ? "danger" : ""}`} onClick={onClick}>{children}</button>;
}

function Toggle({ label, detail, initial = true, disabled = false }) {
  const [checked, setChecked] = useState(initial);
  return (
    <label className={`toggle-row ${disabled ? "disabled" : ""}`}>
      <span><strong>{label}</strong>{detail && <small>{detail}</small>}</span>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(event) => setChecked(event.target.checked)} />
      <span className="toggle-track"><span /></span>
    </label>
  );
}

function Segmented({ options, initial = 0 }) {
  const [selected, setSelected] = useState(initial);
  return (
    <div className="segmented-control">
      {options.map((option, index) => (
        <button className={selected === index ? "active" : ""} key={option} onClick={() => setSelected(index)}>{option}</button>
      ))}
    </div>
  );
}

function SelectRow({ label, options, defaultValue }) {
  return <label className="select-row"><span>{label}</span><select defaultValue={defaultValue || options[0]}>{options.map((option) => <option key={option}>{option}</option>)}</select></label>;
}

function GroupCard({ title, children, className = "" }) {
  return <section className={`group-card ${className}`}><h3>{title}</h3><div className="group-card-body">{children}</div></section>;
}

function WindowChrome({ title, children, className = "" }) {
  return (
    <div className={`mac-window ${className}`}>
      <div className="titlebar">
        <div className="traffic-lights"><i /><i /><i /></div>
        <strong>{title}</strong>
        <span />
      </div>
      {children}
    </div>
  );
}

function UIStandards() {
  const typeSamples = [
    ["Display", "26", "Product screen title"],
    ["Title", "20", "Dialog and state title"],
    ["Heading", "16", "Command and section heading"],
    ["Body", "14", "Primary content"],
    ["Label", "12", "Control label"],
    ["Meta", "11", "Supporting detail"],
    ["Caption", "10", "Section metadata"],
    ["Micro", "9", "Badges only"],
  ];
  return (
    <div className="standards-panel standard-panel">
      <header className="standards-header">
        <span>KEYESTRO FOUNDATION</span>
        <h2>One geometry system</h2>
        <p>Light and Dark change color tokens only. Size, type, radius, spacing, and state remain identical.</p>
      </header>
      <div className="standards-grid">
        <section className="standards-card standards-type">
          <h3>Type ramp</h3>
          {typeSamples.map(([name, size, use]) => <div className={`type-sample type-${name.toLowerCase()}`} key={name}><strong>{name}</strong><span>{size}px</span><small>{use}</small></div>)}
        </section>
        <section className="standards-card standards-controls">
          <h3>Control heights + radii</h3>
          <div className="standard-search"><MagnifyingGlass size={22}/><span>Search</span><small>54 / 16</small></div>
          <div className="standard-toolbar"><MagnifyingGlass size={18}/><span>Toolbar field</span><small>44 / 12</small></div>
          <button className="standard-button">Standard button <small>32 / 8</small></button>
          <button className="standard-compact">Compact control <small>28 / 8</small></button>
          <h3 className="standards-subhead">Spacing</h3>
          <div className="spacing-scale">{[4, 8, 12, 16, 24, 32].map((value) => <span key={value}><i style={{ width: value }} />{value}</span>)}</div>
        </section>
        <section className="standards-card standards-rows">
          <h3>Row density</h3>
          <div className="standard-row row-result"><span>Launcher result</span><small>66 / radius 28 · locked</small></div>
          <div className="standard-row row-command"><span>Command</span><small>54 / radius 16</small></div>
          <div className="standard-row row-list"><span>Content list</span><small>60 / radius 12</small></div>
          <div className="standard-row row-setting"><span>Settings navigation</span><small>32 / radius 8</small></div>
        </section>
      </div>
    </div>
  );
}

const launcherItems = [
  { name: "Bongo Cat", icon: "bongo", action: "Open file" },
  { name: "1Password", icon: "password", action: "Open" },
  { name: "1Password for Safari", icon: "password", action: "Open" },
  { name: "Activity Monitor", icon: "activity", action: "Open" },
  { name: "Contacts", icon: "contacts", action: "Open" },
];

function LauncherHeader({ query, setQuery, busy = false }) {
  return (
    <div className="launcher-header">
      <div className="launcher-search glass-inset">
        <Icon name="search" size={27} />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search apps, files, and commands" />
        {busy && <span className="spinner" />}
      </div>
    </div>
  );
}

function LauncherResults({ overlay = null }) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  return (
    <div className="launcher-panel liquid-panel">
      <LauncherHeader query={query} setQuery={setQuery} />
      <div className="launcher-results">
        {launcherItems.map((item, index) => (
          <button className={`launcher-row ${selected === index ? "selected" : ""}`} key={item.name} onClick={() => setSelected(index)}>
            <span className="launcher-app-icon"><AppIcon kind={item.icon} /></span>
            <strong>{item.name}</strong>
            {selected === index && <span className="row-action">{item.action} <b>↩</b></span>}
          </button>
        ))}
      </div>
      {overlay === "confirm" && (
        <div className="modal-scrim">
          <div className="confirmation-card glass-card">
            <div className="dialog-title"><Icon name="warning" size={20} /> Confirm action</div>
            <h2>Quit Bongo Cat?</h2>
            <div className="labeled-line"><span>Target</span><strong>Bongo Cat</strong></div>
            <p>This action affects something outside Keyestro. Review the target before continuing.</p>
            <div className="dialog-actions"><SecondaryButton>Cancel</SecondaryButton><PrimaryButton>Continue</PrimaryButton></div>
          </div>
        </div>
      )}
    </div>
  );
}

function LauncherActions() {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState("open");
  const actions = [
    { id: "open", icon: Lightning, label: "Open", detail: "Open Bongo Cat", shortcut: "Return" },
    { id: "finder", icon: FolderOpen, label: "Show in Finder", detail: "Reveal in Finder", shortcut: "⌘ I" },
    { id: "copy", icon: CopyIcon, label: "Copy Path", detail: "Copy full file path", shortcut: "⌘ C" },
    { id: "favorite", icon: Star, label: "Add to Favorites", detail: "Keep near the top of results", shortcut: "⌘ D" },
    { id: "quit", icon: Warning, label: "Quit Application", detail: "Close Bongo Cat", shortcut: "⌘ Q", danger: true },
  ];
  const filteredActions = actions.filter((action) => `${action.label} ${action.detail}`.toLowerCase().includes(query.toLowerCase()));
  return (
    <div className="launcher-panel liquid-panel">
      <div className="action-search-wrap">
        <label className="action-search glass-inset">
          <MagnifyingGlass size={27} weight="regular" />
          <input aria-label="Search actions for Bongo Cat" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search actions for Bongo Cat" />
          <span>Esc</span>
        </label>
      </div>
      <div className="action-summary"><strong>Actions for Bongo Cat</strong><span>{filteredActions.length}</span></div>
      <div className="action-command-list" role="listbox" aria-label="Actions for Bongo Cat">
        {filteredActions.map((action) => {
          const ActionIcon = action.icon;
          return (
            <div className={`action-command-item ${action.danger ? "danger" : ""}`} key={action.id}>
              <button className={selected === action.id ? "selected" : ""} role="option" aria-selected={selected === action.id} onClick={() => setSelected(action.id)}>
                <ActionIcon size={25} weight="regular" />
                <span className="action-command-copy"><strong>{action.label}</strong><small>{action.detail}</small></span>
                <span className="action-shortcut">{action.id === "open" && <ArrowElbowDownLeft size={17} weight="regular" />}{action.shortcut}</span>
              </button>
            </div>
          );
        })}
        {filteredActions.length === 0 && <div className="action-empty">No matching actions</div>}
      </div>
    </div>
  );
}

function LauncherParameters() {
  const [query, setQuery] = useState("Create Quick Link");
  return (
    <div className="launcher-panel liquid-panel">
      <LauncherHeader query={query} setQuery={setQuery} />
      <form className="parameter-form" onSubmit={(event) => event.preventDefault()}>
        <div className="parameter-heading"><div><strong>Parameters</strong><span>Create Quick Link</span></div><small>Tab Next · Esc Back</small></div>
        <label><span>Title <em>Required</em></span><input defaultValue="Search Web" /></label>
        <label><span>URL Template <em>Required</em></span><input defaultValue="https://example.com/search?q={query}" /></label>
        <label><span>Browser</span><select defaultValue="Default Browser"><option>Default Browser</option><option>Safari</option><option>Chrome</option></select></label>
        <div className="parameter-actions"><SecondaryButton>Back</SecondaryButton><PrimaryButton>Run</PrimaryButton></div>
      </form>
    </div>
  );
}

const clipboardEntries = [
  { id: "brief", type: "Text", title: "Product brief — Keyestro", detail: "Copied 2 minutes ago", icon: FileText, section: "Today", preview: ["Keyestro is a native macOS productivity tool that keeps commands, clipboard history, and shortcuts at your fingertips.", "Fast launcher", "Clipboard history with quick paste", "Secure, local-first", "— End of brief —"] },
  { id: "docs", type: "Link", title: "OpenAI API documentation", detail: "platform.openai.com", icon: LinkSimple, section: "Today", preview: ["platform.openai.com/docs", "Open the documentation in your default browser."] },
  { id: "screenshot", type: "Image", title: "Screenshot 2026-08-25", detail: "1440 × 900 PNG", icon: ImageSquare, section: "Today", preview: ["Captured from Finder", "1440 × 900 · PNG · 1.2 MB"] },
  { id: "key", type: "Text", title: "ssh-rsa ••••••••••••••••", detail: "Sensitive · preview hidden", icon: Lock, section: "Today", sensitive: true, preview: ["Sensitive preview hidden", "Reveal only after explicit selection."] },
  { id: "notes", type: "Text", title: "Meeting notes and follow-ups", detail: "Copied yesterday", icon: FileText, section: "Today", preview: ["Project sync notes", "Follow up on the launcher action flow and clipboard privacy states."] },
  { id: "site", type: "Link", title: "https://keyestro.app", detail: "keyestro.app", icon: LinkSimple, section: "Yesterday", preview: ["keyestro.app", "Open the Keyestro website in your default browser."] },
];

const clipboardFilters = ["All", "Text", "Images", "Links"];

function ClipboardHeader({ query, setQuery, filter, onFilter }) {
  return (
    <div className="clipboard-header">
      <label className="clipboard-search">
        <MagnifyingGlass size={20} weight="regular" />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search Clipboard History" />
        <span className="clipboard-escape">Esc</span>
      </label>
      <div className="clipboard-filter-tabs" role="tablist" aria-label="Clipboard type">
        {clipboardFilters.map((item) => <button className={filter === item ? "active" : ""} role="tab" aria-selected={filter === item} key={item} onClick={() => onFilter?.(item)}>{item}</button>)}
      </div>
    </div>
  );
}

function ClipboardFooter({ count = 0, mode = "results" }) {
  return <div className="clipboard-footer"><span>{mode === "results" ? `${count} items` : mode === "disabled" ? "Clipboard history is off" : `${count} matching items`}</span><span className="footer-spacer" />{mode !== "disabled" && <><span><KeyCap>↩</KeyCap> Paste</span><span><KeyCap>⌘ C</KeyCap> Copy</span></>}</div>;
}

function ClipboardHistory({ initialFilter = "All", initialQuickView = true }) {
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState(initialFilter);
  const [selected, setSelected] = useState("brief");
  const [quickViewOpen, setQuickViewOpen] = useState(initialQuickView);
  const [feedback, setFeedback] = useState("");
  const visibleEntries = clipboardEntries.filter((entry) => {
    const typeMatch = filter === "All" || (filter === "Images" ? entry.type === "Image" : filter === "Links" ? entry.type === "Link" : entry.type === filter);
    const queryMatch = `${entry.title} ${entry.detail}`.toLowerCase().includes(query.toLowerCase());
    return typeMatch && queryMatch;
  });
  const selectedEntry = visibleEntries.find((entry) => entry.id === selected) || visibleEntries[0];
  const chooseEntry = (entry) => {
    setSelected(entry.id);
    setQuickViewOpen(true);
    setFeedback("");
  };
  return (
    <div className="clipboard-panel liquid-panel">
      <ClipboardHeader query={query} setQuery={setQuery} filter={filter} onFilter={(nextFilter) => { setFilter(nextFilter); setQuickViewOpen(false); }} />
      <div className="clipboard-workspace">
        <div className="clipboard-list">
          {["Today", "Yesterday"].map((section) => {
            const entries = visibleEntries.filter((entry) => entry.section === section);
            if (entries.length === 0) return null;
            return <section className="clipboard-section" key={section}><div className="list-section-label">{section.toUpperCase()}</div>{entries.map((entry) => {
              const EntryIcon = entry.icon;
              return <button className={`clipboard-row ${selectedEntry?.id === entry.id ? "selected" : ""}`} key={entry.id} onClick={() => chooseEntry(entry)}>
                <span className="entry-icon"><EntryIcon size={22} weight="regular" /></span>
                <span><strong>{entry.title}</strong><small>{entry.detail}</small></span>
                <em>{entry.type.toUpperCase()}</em>
              </button>;
            })}</section>;
          })}
          {visibleEntries.length === 0 && <div className="clipboard-empty"><MagnifyingGlass size={24} /><strong>No clipboard items</strong><span>Try a different search or type filter.</span></div>}
        </div>
        {quickViewOpen && selectedEntry && <ClipboardQuickView entry={selectedEntry} feedback={feedback} onClose={() => setQuickViewOpen(false)} onPaste={() => setFeedback("paste")} onCopy={() => setFeedback("copy")} />}
      </div>
      <ClipboardFooter count={visibleEntries.length} mode={filter === "All" ? "results" : "filtered"} />
    </div>
  );
}

function ClipboardQuickView({ entry, feedback, onClose, onPaste, onCopy }) {
  const PreviewIcon = entry.icon;
  return (
    <aside className="quick-view">
      <button className="quick-view-close" aria-label="Close Quick View" onClick={onClose}><X size={16} /></button>
      <div className="quick-view-heading"><PreviewIcon size={30} weight="regular" /><div><small>{entry.type.toUpperCase()}</small><strong>{entry.title}</strong><span>{entry.detail}</span></div></div>
      <div className={`quick-view-content ${entry.sensitive ? "sensitive" : ""}`}>
        {entry.preview.map((line, index) => index === 0 ? <p key={line}>{line}</p> : <span className={line.startsWith("—") ? "preview-end" : ""} key={line}>{entry.preview.length > 2 && !line.startsWith("—") ? "• " : ""}{line}</span>)}
      </div>
      <div className="quick-view-actions">
        <button className="quick-paste" onClick={onPaste}>{feedback === "paste" ? "Pasted to Active App" : "Paste to Active App"}<ArrowElbowDownLeft size={17} weight="regular" /></button>
        <button className="quick-copy" onClick={onCopy}>{feedback === "copy" ? "Copied" : "Copy"}<span>⌘ C</span></button>
      </div>
    </aside>
  );
}

function ClipboardFilters() {
  return <ClipboardHistory initialFilter="Images" initialQuickView={false} />;
}

function ClipboardDisabled() {
  const [query, setQuery] = useState("");
  return (
    <div className="clipboard-panel liquid-panel">
      <ClipboardHeader query={query} setQuery={setQuery} filter="All" />
      <div className="store-state"><ClipboardText size={38} weight="regular"/><h2>Clipboard History Is Off</h2><p>Enable clipboard history to save future copied items locally with encryption.</p><PrimaryButton>Enable Clipboard History</PrimaryButton></div>
      <ClipboardFooter mode="disabled" />
    </div>
  );
}

function SettingsSidebar({ selected }) {
  return <aside className="settings-sidebar">{NAV_ITEMS.map(([id, icon, label]) => <div className={selected === id ? "active" : ""} key={id}><Icon name={icon} size={16}/><span>{label}</span></div>)}</aside>;
}

function ShortcutRecorder() {
  const actions = [["Launcher", "⌥ Space"], ["Clipboard History", "⌥ ⇧ V"], ["Quick Paste", "⌥ ⇧ P"], ["Capture Text", "⌥ ⇧ O"]];
  return <GroupCard title="Global Shortcuts" className="shortcut-card">{actions.map(([label, keys]) => <div className="shortcut-row" key={label}><span>{label}</span><button>{keys}</button></div>)}<p>Use Command, Option, or Control with another key. Conflicts remain visible.</p></GroupCard>;
}

function SettingsContent({ section }) {
  switch (section) {
    case "general":
      return <><GroupCard title="Appearance"><div className="appearance-row"><span>Launcher appearance</span><Segmented options={["Auto", "Light", "Dark"]}/></div><p>Auto follows the macOS appearance. A Light or Dark override is saved on this Mac.</p></GroupCard><Toggle label="Show Keyestro in the Dock" detail="Keyestro remains available from the menu bar when the Dock icon is hidden." initial={false}/><Toggle label="Open Keyestro at Login" detail="macOS may request approval in Login Items."/></>;
    case "shortcuts":
      return <><ShortcutRecorder/><Toggle label="Command-number opens visible results"/><Toggle label="Enable /, >, =, and @ query prefixes"/></>;
    case "features":
      return <><GroupCard title="File Search"><Toggle label="Enable file search"/><Toggle label="Search indexed file contents"/><Toggle label="Include hidden files" initial={false}/><Toggle label="Include system locations" initial={false}/><p>Keyestro asks for folder access only when a search first needs it.</p></GroupCard><GroupCard title="Clipboard & Quick Paste"><Toggle label="Clipboard history"/><Toggle label="Pause clipboard monitoring" initial={false}/><Toggle label="Paste directly into the active app"/><SelectRow label="Clipboard retention" options={["1 day", "7 days", "30 days or 1,000 items", "90 days"]} defaultValue="30 days or 1,000 items"/></GroupCard><GroupCard title="OCR"><SelectRow label="Recognition languages" options={["Automatic", "English + 简体中文", "English", "日本語"]}/><p>Vision accurate mode runs locally and never sends screenshots to a network service.</p></GroupCard><GroupCard title="Quick Links"><div className="mini-list"><span><Icon name="search"/>Search Web <small>https://example.com/?q={'{query}'}</small></span><SecondaryButton>Add Quick Link</SecondaryButton></div></GroupCard></>;
    case "extensions":
      return <><div className="section-action"><strong>Installed Extensions</strong><SecondaryButton>Install Local Extension…</SecondaryButton></div><div className="extension-card"><div className="extension-head"><span className="extension-icon"><Icon name="puzzle"/></span><span><strong>Developer Tools</strong><small>com.keyestro.devtools · 1.2.0</small></span><Toggle label=""/></div><p>Search project commands and run explicitly enabled local workflows.</p><Toggle label="Include in general search" initial={false}/><div className="hash-line">SHA-256 a92f…c18d <SecondaryButton danger>Remove…</SecondaryButton></div></div><div className="extension-card muted"><div className="extension-head"><span className="extension-icon"><Icon name="warning"/></span><span><strong>Example Extension</strong><small>Reinstallation required</small></span><SecondaryButton>Select Package…</SecondaryButton></div><p>Select the exact exported package. Identifier, version, and SHA-256 must match.</p></div></>;
    case "permissions":
      return <><p className="lead-copy">Permissions are requested only when a feature needs them.</p><PermissionCard icon="hand" title="Accessibility" allowed={false} detail="Required only for Quick Paste into another application."/><PermissionCard icon="monitor" title="Screen Recording" allowed detail="Used for region capture and local OCR."/></>;
    case "privacy":
      return <><p className="lead-copy">Raw queries are never persisted. Clipboard, screenshots, and diagnostics remain local unless you explicitly export them.</p><Toggle label="Learn from successful actions" detail="Manual pins continue to affect ranking when learning is off."/><GroupCard title="Clipboard Privacy"><div className="metric-row"><span>Encrypted entries</span><strong>248</strong></div><div className="metric-row"><span>Storage used</span><strong>18.4 MiB</strong></div><div className="button-row"><SecondaryButton>Rotate Encryption Key</SecondaryButton><SecondaryButton danger>Delete Clipboard History…</SecondaryButton></div></GroupCard><div className="button-row"><SecondaryButton danger>Clear ranking history…</SecondaryButton><SecondaryButton danger>Delete All Local Data and Quit…</SecondaryButton></div></>;
    case "updates":
      return <><Toggle label="Automatically check for updates"/><Toggle label="Automatically download updates" initial={false}/><SelectRow label="Update channel" options={["Stable", "Beta"]}/><div className="update-card"><span className="update-icon"><Icon name="update" size={24}/></span><span><strong>Keyestro is up to date</strong><small>Version 0.1.0 (1)</small></span><PrimaryButton>Check Now</PrimaryButton></div></>;
    case "advanced":
      return <><GroupCard title="Performance"><SelectRow label="Pasteboard polling interval" options={["Balanced", "Responsive", "Low energy"]}/><Toggle label="Enable performance diagnostics" initial={false}/></GroupCard><GroupCard title="Diagnostics"><Toggle label="Include anonymized timing details"/><div className="button-row"><SecondaryButton>Export Diagnostics…</SecondaryButton><SecondaryButton>Open Logs</SecondaryButton></div></GroupCard><GroupCard title="Configuration"><div className="button-row"><SecondaryButton>Export Configuration…</SecondaryButton><SecondaryButton>Import Configuration…</SecondaryButton></div></GroupCard><div className="button-row"><SecondaryButton>Clear Caches</SecondaryButton><SecondaryButton danger>Restore default settings…</SecondaryButton></div></>;
    case "about":
      return <div className="about-panel"><div className="about-mark"><Icon name="command" size={38}/></div><h2>Keyestro 0.1.0 (1)</h2><p>Native, open source, and local-first.</p><p>Apache-2.0 licensed.</p><div className="about-links"><SecondaryButton>View Source</SecondaryButton><SecondaryButton>Privacy Policy</SecondaryButton></div></div>;
    default:
      return null;
  }
}

function PermissionCard({ icon, title, allowed, detail }) {
  return <div className="permission-card"><span className={allowed ? "permission-icon allowed" : "permission-icon"}><Icon name={icon} size={21}/></span><span><strong>{title}</strong><small>{detail}</small></span><em className={allowed ? "allowed" : ""}>{allowed ? "Allowed" : "Not allowed"}</em><SecondaryButton>{allowed ? "Open System Settings" : "Request Access"}</SecondaryButton></div>;
}

function SettingsWindow({ section }) {
  const title = NAV_ITEMS.find(([id]) => id === section)?.[2] || "Settings";
  return <WindowChrome title="Keyestro Settings" className="settings-window"><div className="settings-layout"><SettingsSidebar selected={section}/><section className="settings-detail"><h1>{title}</h1><div className="settings-scroll"><SettingsContent section={section}/></div></section></div></WindowChrome>;
}

const onboardingSteps = [
  { id: "shortcut", icon: "keyboard", title: "Your launcher shortcut" },
  { id: "features", icon: "command", title: "Search and act locally" },
  { id: "permissions", icon: "hand", title: "Permissions are requested only when needed" },
];

function OnboardingWindow({ step }) {
  const index = onboardingSteps.findIndex((item) => item.id === step);
  const current = onboardingSteps[index];
  return <WindowChrome title="Welcome to Keyestro" className="onboarding-window"><div className="onboarding-content"><div className="step-progress">{onboardingSteps.map((item, itemIndex) => <i className={itemIndex <= index ? "filled" : ""} key={item.id}/>)}</div><span className="hero-symbol"><Icon name={current.icon} size={48}/></span><h1>{current.title}</h1><OnboardingStep step={step}/><div className="onboarding-actions"><SecondaryButton>Skip setup</SecondaryButton><span/>{index > 0 && <SecondaryButton>Back</SecondaryButton>}<PrimaryButton>{index === 2 ? "Done" : "Continue"}</PrimaryButton></div></div></WindowChrome>;
}

function OnboardingStep({ step }) {
  if (step === "shortcut") return <div className="shortcut-step"><KeyCap>⌥ Space</KeyCap><p>Use this shortcut from any application. You can change it later in Shortcuts settings.</p></div>;
  if (step === "features") return <div className="feature-list"><span><Icon name="search"/>Find applications and Spotlight-indexed files</span><span><strong>ƒ</strong>Calculate and convert units without a network request</span><span><Icon name="bolt"/>Run only the local workflows you explicitly enable</span></div>;
  return <div className="permission-step"><strong>Keyestro does not request Accessibility or Screen Recording during setup.</strong><p>When a feature needs additional access, Keyestro explains why and links directly to the relevant System Settings pane.</p></div>;
}

function CaptureRegion() {
  return <div className="capture-screen"><svg viewBox="0 0 900 520" preserveAspectRatio="none" aria-hidden="true"><defs><linearGradient id="capture-bg" x1="0" y1="0" x2="1" y2="1"><stop stopColor="#2e72a2"/><stop offset=".48" stopColor="#8cc4bd"/><stop offset="1" stopColor="#efc88e"/></linearGradient><mask id="capture-hole"><rect width="900" height="520" fill="white"/><rect x="215" y="105" width="470" height="285" fill="black"/></mask></defs><rect width="900" height="520" fill="url(#capture-bg)"/><path d="M0 360c180-100 290-70 410 10 165 110 300 35 490-100v250H0Z" fill="#163e61" opacity=".58"/><rect width="900" height="520" fill="#000" opacity=".44" mask="url(#capture-hole)"/><rect x="215" y="105" width="470" height="285" fill="none" stroke="var(--accent)" strokeWidth="2"/><rect x="215" y="105" width="470" height="285" fill="#fff" opacity=".06"/></svg><div className="capture-instruction">Drag to select · Return to capture · Esc to cancel</div><div className="capture-size">470 × 285 pt</div></div>;
}

function OCRWindow() {
  return <WindowChrome title="Recognized Text" className="ocr-window"><textarea defaultValue={"Keyestro UI Reference\n\nLight and Dark share the same component structure, dimensions, spacing, and states.\n\nAll processing stays on this Mac."}/><div className="ocr-footer"><span>Review the local Vision result before copying.</span><PrimaryButton>Copy Text</PrimaryButton></div></WindowChrome>;
}

function MenuBarMenu() {
  const items = ["Open Keyestro", "Launcher shortcut: ⌥ Space", "Open Clipboard History", "Clipboard shortcut: ⌥ ⇧ V", "—", "Turn Clipboard Monitoring Off", "Permissions: Review", "—", "Settings…     ⌘,", "Check for Updates…", "—", "Quit Keyestro     ⌘Q"];
  return <div className="menu-stage"><div className="menu-bar"><span>●</span><span>Keyestro</span><span className="menu-spacer"/><span>⌘</span><span>Tue Aug 25&nbsp;&nbsp;20:42</span></div><div className="status-menu glass-card">{items.map((item, index) => item === "—" ? <hr key={index}/> : <button className={item.includes("shortcut") ? "disabled" : ""} key={item}>{item}</button>)}</div></div>;
}

function HUDAndDialogs() {
  return <div className="hud-stage"><div className="hud-message glass-card"><span className="hud-icon success"><Icon name="check" size={20}/></span><strong>Copied text was pasted into the active app.</strong></div><div className="hud-message glass-card"><span className="hud-icon info"><Icon name="info" size={20}/></span><strong>Extension workflow completed.</strong></div><div className="confirmation-card glass-card compact"><div className="dialog-title"><Icon name="warning" size={20}/> Clear clipboard history?</div><p>This permanently deletes encrypted clipboard entries. This cannot be undone.</p><div className="dialog-actions"><SecondaryButton>Cancel</SecondaryButton><SecondaryButton danger>Clear All</SecondaryButton></div></div><div className="loading-card glass-card"><span className="spinner"/><strong>Executing action…</strong><SecondaryButton>Cancel</SecondaryButton></div></div>;
}

const SETTINGS_SCREENS = NAV_ITEMS.map(([id, , label]) => ({
  id: `settings-${id}`,
  title: label,
  group: "Settings",
  description: `Standard macOS settings window · ${label} section`,
  width: 780,
  height: 540,
  singleScale: .94,
  compareScale: .61,
}));

const ONBOARDING_SCREENS = onboardingSteps.map((step) => ({
  id: `onboarding-${step.id}`,
  title: step.title,
  group: "Onboarding",
  description: `Onboarding step ${onboardingSteps.findIndex((item) => item.id === step.id) + 1} of 3`,
  width: 600,
  height: 440,
  singleScale: 1,
  compareScale: .74,
}));

const SCREENS = [
  { id: "foundations-standards", title: "UI Standard", group: "Foundations", description: "Enforced type, control, row, radius, and spacing scales", width: 800, height: 620, singleScale: .91, compareScale: .57 },
  { id: "launcher-results", title: "Results", group: "Launcher", description: "Primary launcher · five visible rows · selected row glass overlaps the panel edge", width: 664, height: 414, singleScale: 1, compareScale: .72 },
  { id: "launcher-actions", title: "Actions", group: "Launcher", description: "Unified command palette · searchable actions · strict shortcut column", width: 664, height: 414, singleScale: 1, compareScale: .72 },
  { id: "launcher-parameters", title: "Parameters", group: "Launcher", description: "Action parameter entry without structural theme drift", width: 664, height: 414, singleScale: 1, compareScale: .72 },
  { id: "launcher-confirmation", title: "Confirmation", group: "Launcher", description: "Risk confirmation overlay on the launcher", width: 664, height: 414, singleScale: 1, compareScale: .72 },
  { id: "clipboard-history", title: "History + Quick View", group: "Clipboard", description: "Full-width history · temporary floating Quick View · two decisive actions", width: 800, height: 620, singleScale: .91, compareScale: .57 },
  { id: "clipboard-filters", title: "Filtered History", group: "Clipboard", description: "Persistent type filters without leaving the history surface", width: 800, height: 620, singleScale: .91, compareScale: .57 },
  { id: "clipboard-disabled", title: "Disabled State", group: "Clipboard", description: "Clipboard history opt-in state", width: 800, height: 620, singleScale: .91, compareScale: .57 },
  ...SETTINGS_SCREENS,
  ...ONBOARDING_SCREENS,
  { id: "capture-region", title: "Region Capture", group: "Capture & OCR", description: "Full-screen dim layer, selection border, size label, and instructions", width: 900, height: 520, singleScale: .82, compareScale: .51 },
  { id: "ocr-result", title: "Recognized Text", group: "Capture & OCR", description: "Editable OCR result with local-processing note", width: 620, height: 440, singleScale: 1, compareScale: .72 },
  { id: "menu-bar", title: "Menu Bar", group: "System Surfaces", description: "Status item menu and shortcut status rows", width: 720, height: 520, singleScale: .96, compareScale: .62 },
  { id: "hud-dialogs", title: "HUDs + Dialogs", group: "System Surfaces", description: "Quick Paste HUD, extension HUD, confirmation, and executing state", width: 720, height: 520, singleScale: .96, compareScale: .62 },
];

export const SCREEN_MAP = Object.fromEntries(SCREENS.map((screen) => [screen.id, screen]));

export const SCREEN_GROUPS = ["Foundations", "Launcher", "Clipboard", "Settings", "Onboarding", "Capture & OCR", "System Surfaces"].map((label) => ({
  label,
  screens: SCREENS.filter((screen) => screen.group === label),
}));

export function ScreenRenderer({ id }) {
  if (id.startsWith("settings-")) return <SettingsWindow section={id.replace("settings-", "")} />;
  if (id.startsWith("onboarding-")) return <OnboardingWindow step={id.replace("onboarding-", "")} />;
  switch (id) {
    case "foundations-standards": return <UIStandards/>;
    case "launcher-results": return <LauncherResults/>;
    case "launcher-actions": return <LauncherActions/>;
    case "launcher-parameters": return <LauncherParameters/>;
    case "launcher-confirmation": return <LauncherResults overlay="confirm"/>;
    case "clipboard-history": return <ClipboardHistory/>;
    case "clipboard-filters": return <ClipboardFilters/>;
    case "clipboard-disabled": return <ClipboardDisabled/>;
    case "capture-region": return <CaptureRegion/>;
    case "ocr-result": return <OCRWindow/>;
    case "menu-bar": return <MenuBarMenu/>;
    case "hud-dialogs": return <HUDAndDialogs/>;
    default: return null;
  }
}
