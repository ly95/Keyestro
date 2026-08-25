import { useMemo, useState } from "react";
import { IconSprite } from "./icons.jsx";
import { SCREEN_GROUPS, SCREEN_MAP, ScreenRenderer } from "./screens.jsx";

const VIEW_MODES = [
  { id: "compare", label: "Compare" },
  { id: "light", label: "Light" },
  { id: "dark", label: "Dark" },
];

function Preview({ screen, theme, compare }) {
  const scale = compare ? screen.compareScale : screen.singleScale;
  return (
    <article className="preview-column">
      <div className="preview-label">
        <span>{theme === "light" ? "LIGHT" : "DARK"}</span>
        <span>{screen.width} × {screen.height}</span>
      </div>
      <div className="desktop-scene" data-theme={theme}>
        <svg className="ambient-art" viewBox="0 0 1200 820" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
          <defs>
            <radialGradient id={`ambient-a-${theme}`} cx="50%" cy="50%" r="50%">
              <stop offset="0" stopColor="var(--ambient-a)" stopOpacity=".92" />
              <stop offset="1" stopColor="var(--ambient-a)" stopOpacity="0" />
            </radialGradient>
            <radialGradient id={`ambient-b-${theme}`} cx="50%" cy="50%" r="50%">
              <stop offset="0" stopColor="var(--ambient-b)" stopOpacity=".82" />
              <stop offset="1" stopColor="var(--ambient-b)" stopOpacity="0" />
            </radialGradient>
            <filter id={`ambient-blur-${theme}`} x="-40%" y="-40%" width="180%" height="180%">
              <feGaussianBlur stdDeviation="52" />
            </filter>
            <filter id={`grain-${theme}`} x="0" y="0" width="100%" height="100%">
              <feTurbulence type="fractalNoise" baseFrequency=".72" numOctaves="3" seed="8" />
              <feColorMatrix type="saturate" values="0" />
              <feComponentTransfer><feFuncA type="table" tableValues="0 .055" /></feComponentTransfer>
            </filter>
          </defs>
          <rect width="1200" height="820" fill="var(--desktop-base)" />
          <ellipse cx="225" cy="165" rx="360" ry="310" fill={`url(#ambient-a-${theme})`} filter={`url(#ambient-blur-${theme})`} />
          <ellipse cx="985" cy="640" rx="390" ry="330" fill={`url(#ambient-b-${theme})`} filter={`url(#ambient-blur-${theme})`} />
          <path d="M-40 650 C230 480 365 730 645 540 C860 394 995 402 1240 218 L1240 860 L-40 860Z" fill="var(--ambient-ribbon)" opacity=".48" filter={`url(#ambient-blur-${theme})`} />
          <rect width="1200" height="820" filter={`url(#grain-${theme})`} opacity=".52" />
        </svg>
        <div
          className="native-stage"
          style={{
            width: screen.width * scale,
            height: screen.height * scale,
          }}
        >
          <div
            className="native-screen"
            style={{
              width: screen.width,
              height: screen.height,
              transform: `scale(${scale})`,
            }}
          >
            <ScreenRenderer id={screen.id} />
          </div>
        </div>
      </div>
    </article>
  );
}

export function App() {
  const [screenId, setScreenId] = useState("launcher-results");
  const [viewMode, setViewMode] = useState("compare");
  const screen = useMemo(() => SCREEN_MAP[screenId], [screenId]);
  const themes = viewMode === "compare" ? ["light", "dark"] : [viewMode];

  return (
    <div className="reference-app">
      <IconSprite />
      <aside className="reference-sidebar">
        <div className="brand-lockup">
          <div className="brand-mark">K</div>
          <div>
            <strong>Keyestro</strong>
            <span>UI Reference</span>
          </div>
        </div>
        <p className="sidebar-note">HTML + SVG source of truth</p>
        <nav aria-label="UI screens">
          {SCREEN_GROUPS.map((group) => (
            <section className="nav-group" key={group.label}>
              <h2>{group.label}</h2>
              {group.screens.map((item) => (
                <button
                  className={screenId === item.id ? "active" : ""}
                  key={item.id}
                  onClick={() => setScreenId(item.id)}
                >
                  <span>{item.title}</span>
                  <small>{item.width}×{item.height}</small>
                </button>
              ))}
            </section>
          ))}
        </nav>
      </aside>

      <main className="reference-main">
        <header className="reference-toolbar">
          <div>
            <span className="eyebrow">{screen.group}</span>
            <h1>{screen.title}</h1>
            <p>{screen.description}</p>
          </div>
          <div className="mode-switch" aria-label="Theme preview">
            {VIEW_MODES.map((mode) => (
              <button
                className={viewMode === mode.id ? "active" : ""}
                key={mode.id}
                onClick={() => setViewMode(mode.id)}
              >
                {mode.label}
              </button>
            ))}
          </div>
        </header>

        <section className={`preview-grid ${viewMode === "compare" ? "is-compare" : "is-single"}`}>
          {themes.map((theme) => (
            <Preview key={`${screen.id}-${theme}`} screen={screen} theme={theme} compare={viewMode === "compare"} />
          ))}
        </section>

        <footer className="reference-contract">
          <div><span>TYPE</span><strong>26 · 20 · 16 · 14 · 12 · 11 · 10 · 9</strong></div>
          <div><span>CONTROLS</span><strong>54 · 44 · 32 · 28</strong></div>
          <div><span>RADII</span><strong>6 · 8 · 12 · 16 · 24 · 28</strong></div>
          <div><span>RESULTS</span><strong>Locked · regression protected</strong></div>
        </footer>
      </main>
    </div>
  );
}
