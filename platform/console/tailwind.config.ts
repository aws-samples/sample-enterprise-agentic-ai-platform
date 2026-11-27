import type { Config } from 'tailwindcss'

export default {
  content: [
    './index.html',
    './src/**/*.{js,ts,jsx,tsx}',
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'sans-serif'],
        mono: ['JetBrains Mono', 'SF Mono', 'Menlo', 'monospace'],
      },
      colors: {
        // Enterprise-grade dark palette
        brand: {
          50: '#f0f4f8',
          100: '#d9e2ec',
          200: '#a0aec0',
          // 300 lightened from #718096 → #8592a6 so secondary text meets
          // WCAG AA (4.5:1) on all dark surfaces (panel/elevated).
          300: '#8592a6',
          400: '#4a5568',
          500: '#2d3748',
          600: '#1a202c',
          700: '#171923',
          800: '#0f1218',
          900: '#0a0d12',
        },
        surface: {
          DEFAULT: '#0f1218',
          panel: '#171923',
          elevated: '#1e2433',
          border: '#2a3040',
        },
        accent: {
          // DEFAULT darkened #3182ce → #2b6cb0 so white text on `bg-accent`
          // (buttons, active nav, chat bubbles) meets WCAG AA (5.4:1).
          DEFAULT: '#2b6cb0',
          hover: '#2c5282',
          muted: '#2a4365',
          // Brighter blue for accent-colored TEXT/links on dark backgrounds
          // (`text-accent-fg`): 8.2:1 on the base surface. Use this instead of
          // `text-accent` for foreground accent so links stay AA-legible.
          fg: '#63b3ed',
        },
        status: {
          success: '#38a169',
          warning: '#d69e2e',
          error: '#e53e3e',
          info: '#3182ce',
        },
      },
    },
  },
  plugins: [],
} satisfies Config
