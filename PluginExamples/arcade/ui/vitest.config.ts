import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./tests/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    css: false,
    // 受限沙箱环境下默认线程池会触发 tinypool 栈溢出，固定为单线程更稳。
    pool: 'threads',
    poolOptions: {
      threads: { singleThread: true },
    },
  },
});
