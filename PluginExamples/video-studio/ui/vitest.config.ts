import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./tests/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    // UI assertions remain unchanged; allow CPU contention with Xcode builds.
    testTimeout: 15_000,
    pool: 'threads',
    poolOptions: { threads: { singleThread: true } },
  },
});
