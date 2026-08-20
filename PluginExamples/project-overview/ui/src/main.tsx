import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";
import en from "./locales/en.json";
import zhHans from "./locales/zh-Hans.json";

const messages = {
  en,
  "zh-Hans": zhHans
} as const;

type Context = { selectedItemID?: string; workspaceReference?: string; locale?: string };
declare global { interface Window { willdeep?: { getContext(): Context } } }

function App() {
  const [context, setContext] = useState<Context>(() => window.willdeep?.getContext() ?? {});
  useEffect(() => {
    const update = (event: Event) => setContext((event as CustomEvent<Context>).detail);
    window.addEventListener("willdeep:context-changed", update);
    return () => window.removeEventListener("willdeep:context-changed", update);
  }, []);
  const language = context.locale?.startsWith("zh") ? "zh-Hans" : "en";
  const t = messages[language];
  return <main><h1>{t.title}</h1><section><b>{t.selected}</b><span>{context.selectedItemID ?? "—"}</span></section><section><b>{t.workspace}</b><span>{context.workspaceReference ? t.granted : t.missing}</span></section></main>;
}

createRoot(document.getElementById("root")!).render(<App />);
