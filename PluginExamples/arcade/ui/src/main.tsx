import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { HashRouter } from './core/hashRouter';
import { I18nProvider } from './core/i18n';
import { App } from './App';
import './styles.css';

const rootElement = document.getElementById('root');
if (!rootElement) throw new Error('缺少 #root 挂载点');

createRoot(rootElement).render(
  <StrictMode>
    <HashRouter>
      <I18nProvider>
        <App />
      </I18nProvider>
    </HashRouter>
  </StrictMode>,
);
