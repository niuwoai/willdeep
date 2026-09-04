import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig(({ command }) => ({
  base: './',
  plugins: [react()],
  // public/demo 里的样例封面只给 dev server 的假数据用（developmentBridge），
  // 生产里 coverURL 永远是 null，没有任何代码引用它们。默认的 publicDir 会把
  // 这三张图无条件拷进 dist，白白进插件安装包，所以构建时关掉。
  publicDir: command === 'serve' ? 'public' : false,
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
}));
