import { readFile } from "node:fs/promises";

const projectRoot = new URL("../", import.meta.url);
const styles = await readFile(new URL("src/styles.css", projectRoot), "utf8");
const tokens = await readFile(new URL("src/tokens.css", projectRoot), "utf8");

const failures = [];
const requireText = (source, text, message) => {
  if (!source.includes(text)) failures.push(message);
};

const requiredTokens = {
  "--type-display": "26px",
  "--type-title": "20px",
  "--type-heading": "16px",
  "--type-body": "14px",
  "--type-label": "12px",
  "--type-meta": "11px",
  "--type-caption": "10px",
  "--type-micro": "9px",
  "--control-search": "54px",
  "--control-toolbar": "44px",
  "--control-button": "32px",
  "--control-compact": "28px",
  "--radius-compact": "6px",
  "--radius-button": "8px",
  "--radius-control": "12px",
  "--radius-search": "16px",
  "--radius-floating": "24px",
  "--radius-launcher": "28px",
  "--launcher-search-type": "23px",
  "--launcher-result-type": "19.5px",
};

for (const [name, value] of Object.entries(requiredTokens)) {
  requireText(tokens, `${name}: ${value};`, `${name} must stay ${value}`);
}

const rawFontSizes = [...styles.matchAll(/font-size:\s*(?:\d|\.)[^;}]*/g)].map((match) => match[0]);
if (rawFontSizes.length) failures.push(`Raw font sizes found in styles.css: ${rawFontSizes.join(", ")}`);

const rawRadii = [...styles.matchAll(/border-radius:\s*([^;}]+)/g)]
  .map((match) => match[1].trim())
  .filter((value) => value !== "50%" && !value.startsWith("var("));
if (rawRadii.length) failures.push(`Raw radii found in styles.css: ${rawRadii.join(", ")}`);

const darkThemeBlock = styles.match(/\.desktop-scene\[data-theme="dark"\]\s*\{([^}]*)\}/)?.[1] || "";
if (/\b(?:width|height|padding|margin|gap|font-size|border-radius)\s*:/.test(darkThemeBlock)) {
  failures.push("Dark theme contains geometry; themes may change color/material tokens only");
}

const requiredBindings = [
  ".launcher-panel { width: 664px; height: 414px; border-radius: var(--radius-launcher); }",
  ".launcher-search { width: 100%; height: var(--control-search);",
  "font-size: var(--launcher-search-type);",
  ".launcher-row { position: relative; width: 100%; height: var(--row-launcher);",
  "font-size: var(--launcher-result-type);",
  ".action-search { width: 100%; height: var(--control-search);",
  ".clipboard-search { height: var(--control-toolbar);",
  ".clipboard-filter-tabs { height: var(--control-toolbar);",
  ".clipboard-row { width: 100%; height: var(--row-list);",
  ".settings-sidebar div { height: var(--row-settings);",
  ".segmented-control { height: var(--control-compact);",
];

for (const binding of requiredBindings) {
  requireText(styles, binding, `Missing required token binding: ${binding}`);
}

if (failures.length) {
  console.error("Design token guard failed:\n" + failures.map((failure) => `- ${failure}`).join("\n"));
  process.exitCode = 1;
} else {
  console.log("Design token guard passed: typography, controls, radii, themes, and locked Results bindings are consistent.");
}
